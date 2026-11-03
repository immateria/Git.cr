require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P27 native hard reset of regular worktrees" do
  ["sha1", "sha256"].each do |format|
    it "P27-O01 resets a dirty and staged #{format} worktree, index and branch" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "keep"), "base\n")
        File.write(File.join(root, "removed"), "old\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "keep"), "later\n")
        File.delete(File.join(root, "removed"))
        File.write(File.join(root, "new"), "later\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "later")
        File.write(File.join(root, "keep"), "dirty\n")
        File.write(File.join(root, "staged"), "staged\n")
        GitOracle.run(root, "add", "staged")
        repo = Git::Repository.new(root)
        result = repo.reset("HEAD~1", mode: Git::Reset::Mode::Hard)
        result.target_oid.should eq(base)
        result.changed_index_paths.to_set.should eq(["keep", "new", "removed", "staged"].to_set)
        result.changed_worktree_paths.to_set.should eq(["keep", "new", "removed", "staged"].to_set)
        File.read(File.join(root, "keep")).should eq("base\n")
        File.read(File.join(root, "removed")).should eq("old\n")
        File.exists?(File.join(root, "new")).should be_false
        File.exists?(File.join(root, "staged")).should be_false
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
        second = repo.reset(mode: Git::Reset::Mode::Hard)
        second.changed_worktree_paths.should be_empty
        second.changed_index_paths.should be_empty
      end
    end

    it "P27-O02 overwrites a dirty tracked #{format} file even when resetting to HEAD" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "one"), "dirty\n")
        repo = Git::Repository.new(root)
        result = repo.reset(mode: Git::Reset::Mode::Hard)
        result.changed_worktree_paths.should eq(["one"])
        result.changed_index_paths.should be_empty
        File.read(File.join(root, "one")).should eq("base\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P27-O03 refuses #{format} untracked collisions before destructive work" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "collision"), "from other branch\n")
        GitOracle.run(root, "add", "collision")
        GitOracle.run(root, "commit", "-qm", "added")
        target = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "--detach", base)
        GitOracle.run(root, "branch", "-f", "main", base)
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "collision"), "untracked\n")
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /untracked path collision/) { repo.reset(target, mode: Git::Reset::Mode::Hard) }
        File.read(File.join(root, "collision")).should eq("untracked\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
      end
    end

    it "P27-O04 reports partial #{format} hard reset after first worktree publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "first\n")
        File.write(File.join(root, "b"), "first\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "a"), "second\n")
        File.write(File.join(root, "b"), "second\n")
        GitOracle.run(root, "commit", "-qam", "later")
        repo = Git::Repository.new(root)
        check = -> do
          raise Git::Error.new("injected after first worktree publication") if File.read(File.join(root, "a")) == "first\n"
        end
        error = expect_raises(Git::Reset::PartialPublication) { repo.reset(base, mode: Git::Reset::Mode::Hard, check: check) }
        error.changed_worktree_paths.should eq(["a"])
        error.reference_published.should be_false
        error.index_published.should be_false
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should_not eq(base)
        File.read(File.join(root, "a")).should eq("first\n")
        File.read(File.join(root, "b")).should eq("second\n")
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end
  end
end
