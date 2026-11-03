require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P26 native symbolic-HEAD reset" do
  ["sha1", "sha256"].each do |format|
    it "P26-O01 soft resets #{format} branch while preserving index and worktree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "first\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "one")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "one"), "second\n")
        GitOracle.run(root, "commit", "-qam", "two")
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        initial_index = File.read(File.join(root, ".git", "index"))
        repo = Git::Repository.new(root)
        result = repo.reset("HEAD^", mode: Git::Reset::Mode::Soft)
        result.reference.should eq("refs/heads/main")
        result.previous_oid.should eq(head)
        result.target_oid.should eq(base)
        result.changed_index_paths.should be_empty
        File.read(File.join(root, ".git", "index")).should eq(initial_index)
        File.read(File.join(root, "one")).should eq("second\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("one\n")
      end
    end

    it "P26-O02 mixed resets #{format} branch, index and preserves dirty worktree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "first\n")
        File.write(File.join(root, "two"), "two\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "one"), "second\n")
        File.delete(File.join(root, "two"))
        File.write(File.join(root, "three"), "three\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "second")
        File.write(File.join(root, "one"), "working\n")
        repo = Git::Repository.new(root)
        result = repo.reset("HEAD^", mode: Git::Reset::Mode::Mixed)
        result.target_oid.should eq(base)
        result.changed_index_paths.to_set.should eq(["one", "two", "three"].to_set)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        File.read(File.join(root, "one")).should eq("working\n")
        File.exists?(File.join(root, "two")).should be_false
        File.read(File.join(root, "three")).should eq("three\n")
        # Compare to Git's own mixed reset after native mutation (idempotent).
        before = GitOracle.run(root, "ls-files", "--stage").stdout
        GitOracle.run(root, "reset", "-q", "--mixed", base)
        GitOracle.run(root, "ls-files", "--stage").stdout.should eq(before)
      end
    end

    it "P26-O03 resets #{format} index to the current HEAD without moving the ref" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "a"), "staged\n")
        GitOracle.run(root, "add", "a")
        repo = Git::Repository.new(root)
        result = repo.reset
        result.previous_oid.should eq(head)
        result.target_oid.should eq(head)
        result.changed_index_paths.should eq(["a"])
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        File.read(File.join(root, "a")).should eq("staged\n")
        repo.reset.changed_index_paths.should be_empty
      end
    end

    it "P26-O04 refuses foreign #{format} index locks without moving HEAD" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "a"), "change\n")
        GitOracle.run(root, "add", "a")
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        repo = Git::Repository.new(root)
        begin
          expect_raises(Git::Error) { repo.reset }
          File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(head)
          GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("a\n")
        ensure
          File.delete(File.join(root, ".git", "index.lock"))
        end
      end
    end

    it "P26-O05 reports partial #{format} reset when interrupted after ref publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "first\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "a"), "second\n")
        GitOracle.run(root, "commit", "-qam", "second")
        repo = Git::Repository.new(root)
        check = -> do
          raise Git::Error.new("injected after ref publication") if repo.head.oid == base
        end
        raised = expect_raises(Git::Reset::PartialPublication) { repo.reset("HEAD^", check: check) }
        raised.reference_published.should be_true
        raised.index_published.should be_false
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("a\n")
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end
  end
end
