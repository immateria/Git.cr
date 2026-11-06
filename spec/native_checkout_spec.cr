require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P23 native Git checkout" do
  ["sha1", "sha256"].each do |format|
    it "P23-O01 switches a clean #{format} branch with modified, new, and deleted regular files" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "keep"), "kept\n")
        File.write(File.join(root, "edit"), "old\n")
        File.write(File.join(root, "remove"), "gone\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        main_oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "feature")
        File.write(File.join(root, "edit"), "new\n")
        Dir.mkdir_p(File.join(root, "nested"))
        File.write(File.join(root, "nested", "added"), "added\n")
        File.chmod(File.join(root, "nested", "added"), 0o755)
        File.delete(File.join(root, "remove"))
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "feature")
        side_oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        repository = Git::Repository.new(root)
        repository.head.should eq(Git::References::Ref.new("HEAD", main_oid, "refs/heads/main"))
        result = repository.switch("feature")
        result.reference.should eq("refs/heads/feature")
        result.commit_oid.should eq(side_oid)
        result.changed_paths.to_set.should eq(["edit", "nested/added", "remove"].to_set)
        GitOracle.run(root, "symbolic-ref", "HEAD").stdout.strip.should eq("refs/heads/feature")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.read(File.join(root, "edit")).should eq("new\n")
        File.file?(File.join(root, "remove")).should be_false
        File.read(File.join(root, "nested", "added")).should eq("added\n")
        (File.info(File.join(root, "nested", "added")).permissions.value & 0o111).should_not eq(0)
        repository.switch("main")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.read(File.join(root, "remove")).should eq("gone\n")
        File.file?(File.join(root, "nested", "added")).should be_false
      end
    end

    it "P23-O02 refuses dirty tracked and staged #{format} paths without publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "branch", "topic")
        repo = Git::Repository.new(root)
        File.write(File.join(root, "a"), "dirty\n")
        expect_raises(Git::Error, /dirty/) { repo.switch("topic") }
        repo.head.symref_target.should eq("refs/heads/main")
        File.read(File.join(root, "a")).should eq("dirty\n")
        GitOracle.run(root, "add", "a")
        expect_raises(Git::Error, /index equal to HEAD/) { repo.switch("topic") }
        repo.head.symref_target.should eq("refs/heads/main")
      end
    end

    it "P23-O03 refuses untracked target collisions in #{format} without overwriting" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "collision"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "collision"), "untracked\n")
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /untracked path collision/) { repo.switch("topic") }
        File.read(File.join(root, "collision")).should eq("untracked\n")
        repo.head.symref_target.should eq("refs/heads/main")
      end
    end

    it "P23-O05 restores explicit #{format} worktree paths but leaves HEAD and index unchanged" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "first\n")
        File.write(File.join(root, "two"), "second\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "initial")
        oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "one"), "dirty\n")
        File.delete(File.join(root, "two"))
        repo = Git::Repository.new(root)
        repo.restore(["one", "two"]).to_set.should eq(["one", "two"].to_set)
        File.read(File.join(root, "one")).should eq("first\n")
        File.read(File.join(root, "two")).should eq("second\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(oid)
        File.write(File.join(root, "one"), "dirty again\n")
        repo.restore(["one"]).should eq(["one"])
        repo.restore(["one"]).should be_empty
        expect_raises(Git::Error, /tracked paths/) { repo.restore(["untracked"]) }
      end
    end

    it "P23-O06 restores #{format} from an older commit without changing the staging index" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "one\n")
        File.write(File.join(root, "obsolete"), "old\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "first")
        first_oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "a"), "two\n")
        File.delete(File.join(root, "obsolete"))
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "second")
        second_oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        repo.restore(["a"], source: first_oid).should eq(["a"])
        File.read(File.join(root, "a")).should eq("one\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(second_oid)
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        GitOracle.run(root, "diff", "--name-only").stdout.should contain("a")
        expect_raises(Git::Error, /tracked paths/) { repo.restore(["obsolete"], source: first_oid) }
      end
    end

    it "P23-O09 restores a #{format} path deleted in an older source without unstaging" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "keep"), "kept\n")
        GitOracle.run(root, "add", "keep")
        GitOracle.run(root, "commit", "-qm", "first")
        before = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "later"), "tracked\n")
        GitOracle.run(root, "add", "later")
        GitOracle.run(root, "commit", "-qm", "second")
        repo = Git::Repository.new(root)
        repo.restore(["later"], source: before).should eq(["later"])
        File.exists?(File.join(root, "later")).should be_false
        GitOracle.run(root, "status", "--porcelain").stdout.should contain(" D later")
        GitOracle.run(root, "diff", "--cached", "--name-only").stdout.should eq("")
        repo.restore(["later"]).should eq(["later"])
        File.read(File.join(root, "later")).should eq("tracked\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P23-O10 refuses a #{format} symlinked destination parent without external writes" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "keep"), "kept\n")
        GitOracle.run(root, "add", "keep")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "other")
        Dir.mkdir_p(File.join(root, "nested"))
        File.write(File.join(root, "nested", "added"), "topic\n")
        GitOracle.run(root, "add", "nested/added")
        GitOracle.run(root, "commit", "-qm", "other")
        GitOracle.run(root, "checkout", "-q", "main")
        external = File.join(File.dirname(root), "external")
        Dir.mkdir_p(external)
        File.write(File.join(external, "sentinel"), "protected\n")
        File.symlink(external, File.join(root, "nested"))
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /symlinked destination parent/) { repo.switch("other") }
        repo.head.symref_target.should eq("refs/heads/main")
        File.read(File.join(external, "sentinel")).should eq("protected\n")
        File.exists?(File.join(external, "added")).should be_false
      end
    end

    it "P23-O07 refuses a foreign #{format} index lock before checkout or restore" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "branch", "other")
        index_lock = File.join(root, ".git", "index.lock")
        File.write(index_lock, "foreign lock")
        repo = Git::Repository.new(root)
        begin
          expect_raises(Git::Error) { repo.switch("other") }
          expect_raises(Git::Error) { repo.restore(["a"]) }
          File.read(index_lock).should eq("foreign lock")
          repo.head.symref_target.should eq("refs/heads/main")
        ensure
          File.delete(index_lock) if File.exists?(index_lock)
        end
      end
    end

    it "P23-O08 exposes partial #{format} checkout after a post-worktree interruption" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "other")
        File.write(File.join(root, "a"), "other\n")
        GitOracle.run(root, "add", "a")
        GitOracle.run(root, "commit", "-qm", "other")
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        guard = -> do
          raise Git::Error.new("injected after worktree write") if File.read(File.join(root, "a")) == "other\n"
          nil
        end
        err = expect_raises(Git::Checkout::PartialPublication) { repo.switch("other", check: guard) }
        err.changed_paths.should eq(["a"])
        err.index_published.should be_false
        repo.head.symref_target.should eq("refs/heads/main")
        File.read(File.join(root, "a")).should eq("other\n")
        File.exists?(File.join(root, ".git", "HEAD.lock")).should be_false
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end

    it "P23-O04 refuses #{format} file/directory flips and unsupported symlinks" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "parent"), "base")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "parent"))
        Dir.mkdir(File.join(root, "parent"))
        File.write(File.join(root, "parent", "child"), "child")
        File.symlink("child", File.join(root, "link"))
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /regular files/) { repo.switch("topic") }
        repo.head.symref_target.should eq("refs/heads/main")
      end
    end
  end
end

describe "P31 native Git checkout file/directory transitions" do
  ["sha1", "sha256"].each do |format|
    it "P31-C01 switches #{format} file-to-directory and back" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node"))
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "topic\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")

        repo = Git::Repository.new(root)
        repo.switch("topic")
        File.read(File.join(root, "node", "child")).should eq("topic\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.switch("main")
        File.file?(File.join(root, "node")).should be_true
        File.read(File.join(root, "node")).should eq("base\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P31-C02 refuses #{format} checkout directory collapse with untracked content" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node"))
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "topic\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")

        repo = Git::Repository.new(root)
        repo.switch("main").reference.should eq("refs/heads/main")
        repo.switch("topic")
        File.write(File.join(root, "node", "untracked"), "keep\n")
        expect_raises(Git::Error, /untracked/) { repo.switch("main") }
        File.read(File.join(root, "node", "untracked")).should eq("keep\n")
        repo.head.symref_target.should eq("refs/heads/topic")
      end
    end
  end
end
