require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P24 index-only restore and reset" do
  ["sha1", "sha256"].each do |format|
    it "P24-O01 restores staged additions, edits and deletions in #{format} without altering worktree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "edit"), "base\n")
        File.write(File.join(root, "removed"), "keep\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        before_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "edit"), "staged\n")
        File.write(File.join(root, "added"), "new\n")
        File.delete(File.join(root, "removed"))
        GitOracle.run(root, "add", "-A")
        repo = Git::Repository.new(root)
        repo.restore_staged(["edit", "added", "removed"]).to_set.should eq(["edit", "added", "removed"].to_set)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        GitOracle.run(root, "status", "--porcelain").stdout.should contain("?? added")
        File.read(File.join(root, "edit")).should eq("staged\n")
        File.exists?(File.join(root, "removed")).should be_false
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(before_head)
        repo.restore_staged(["edit", "removed"]).should be_empty
      end
    end

    it "P24-O02 restores staged paths from a historical #{format} source including new paths" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "first"), "old\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "one")
        old = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.delete(File.join(root, "first"))
        File.write(File.join(root, "later"), "later\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "two")
        repo = Git::Repository.new(root)
        repo.restore_staged(["first", "later"], source: old).to_set.should eq(["first", "later"].to_set)
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("first")
        GitOracle.run(root, "ls-files", "--stage").stdout.should_not contain("later")
        # Git's porcelain pathspec rejects `later` after it is no longer
        # indexed or in the source tree; our explicit path operation similarly
        # rejects it on a subsequent call.
        expect_raises(Git::Error, /neither indexed nor in source/) { repo.restore_staged(["later"], source: old) }
        File.exists?(File.join(root, "first")).should be_false
        File.read(File.join(root, "later")).should eq("later\n")
      end
    end

    it "P24-O03 resets the entire #{format} staged index without moving HEAD or touching worktree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "1\n")
        File.write(File.join(root, "two"), "2\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        old = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "one"), "changed\n")
        File.delete(File.join(root, "two"))
        File.write(File.join(root, "three"), "extra\n")
        GitOracle.run(root, "add", "-A")
        repo = Git::Repository.new(root)
        repo.read_tree.to_set.should eq(["one", "two", "three"].to_set)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        File.read(File.join(root, "one")).should eq("changed\n")
        File.exists?(File.join(root, "two")).should be_false
        File.read(File.join(root, "three")).should eq("extra\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(old)
        repo.read_tree.should be_empty
      end
    end

    it "P24-O04 retains #{format} symlink target bytes with index-only restoration" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "target"), "target\n")
        File.symlink("target", File.join(root, "link"))
        GitOracle.run(root, "add", "target", "link")
        GitOracle.run(root, "commit", "-qm", "symlink")
        old_stage = GitOracle.run(root, "ls-files", "--stage", "--", "link").stdout
        File.delete(File.join(root, "link"))
        File.symlink("different", File.join(root, "link"))
        GitOracle.run(root, "add", "link")
        repo = Git::Repository.new(root)
        repo.restore_staged(["link"]).should eq(["link"])
        GitOracle.run(root, "ls-files", "--stage", "--", "link").stdout.should eq(old_stage)
        File.readlink(File.join(root, "link")).should eq("different")
      end
    end

    it "P24-O05 respects #{format} foreign lock and invalid path/budget/source refusal" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "tracked"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "tracked"), "staged\n")
        GitOracle.run(root, "add", "tracked")
        repo = Git::Repository.new(root)
        original = GitOracle.run(root, "ls-files", "--stage").stdout
        expect_raises(Git::Error, /neither indexed nor in source/) { repo.restore_staged(["missing"]) }
        expect_raises(Git::Error, /duplicate/) { repo.restore_staged(["tracked", "tracked"]) }
        expect_raises(ArgumentError, /budget/) { repo.read_tree(max_entries: 0) }
        expect_raises(Git::Error, /unknown Git revision/) { repo.read_tree("refs/heads/unknown") }
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        begin
          expect_raises(Git::Error) { repo.restore_staged(["tracked"]) }
          expect_raises(Git::Error) { repo.read_tree }
          File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
          GitOracle.run(root, "ls-files", "--stage").stdout.should eq(original)
        ensure
          File.delete(File.join(root, ".git", "index.lock"))
        end
      end
    end

    it "P24-O07 resolves an unmerged #{format} index path using a commit source" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "conflict"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "conflict"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "conflict"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        GitOracle.run(root, "merge", "topic", check: false).success?.should be_false
        GitOracle.run(root, "ls-files", "-u").stdout.should_not eq("")
        conflict_text = File.read(File.join(root, "conflict"))
        repo = Git::Repository.new(root)
        repo.restore_staged(["conflict"]).should eq(["conflict"])
        GitOracle.run(root, "ls-files", "-u").stdout.should eq("")
        File.read(File.join(root, "conflict")).should eq(conflict_text)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
      end
    end

    it "P24-O06 restores #{format} staged paths in version 4 without converting index" do
      GitOracle.with_repo(format: format) do |root|
        Dir.mkdir_p(File.join(root, "folder"))
        File.write(File.join(root, "folder", "one"), "old\n")
        File.write(File.join(root, "folder", "two"), "two\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "update-index", "--index-version", "4")
        File.write(File.join(root, "folder", "one"), "new\n")
        GitOracle.run(root, "add", "folder/one")
        repo = Git::Repository.new(root)
        repo.restore_staged(["folder/one"]).should eq(["folder/one"])
        File.read(File.join(root, ".git", "index")).byte_slice(4, 4).to_slice.hexstring.should eq("00000004")
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
      end
    end
  end
end
