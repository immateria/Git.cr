require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P22 native Git initialization" do
  ["sha1", "sha256"].each do |format|
    [false, true].each do |bare|
      it "P22-O01 creates a #{format} #{bare ? "bare" : "working"} repository compatible with Git" do
        base = File.tempname("git-native-init", dir: File.realpath(Dir.tempdir))
        root = File.join(base, bare ? "bare.git" : "repo")
        oracle = File.join(base, "oracle")
        template = File.join(base, "template")
        Dir.mkdir_p(root)
        Dir.mkdir_p(oracle)
        Dir.mkdir_p(template)
        File.write(File.join(root, "hello.txt"), "hello\n") unless bare
        begin
          selected = format == "sha256" ? Git::ObjectId::Format::SHA256 : Git::ObjectId::Format::SHA1
          native = Git::Repository.init(root, bare: bare, initial_branch: "main",
            object_format: selected)
          admin = bare ? root : File.join(root, ".git")
          if bare
            GitOracle.run(oracle, "init", "-q", "--initial-branch=main", "--object-format=#{format}",
              "--template=#{template}", "--bare")
          else
            GitOracle.run(oracle, "init", "-q", "--initial-branch=main", "--object-format=#{format}",
              "--template=#{template}")
          end
          other = bare ? oracle : File.join(oracle, ".git")
          File.read(File.join(admin, "config")).should eq(File.read(File.join(other, "config")))
          File.read(File.join(admin, "HEAD")).should eq(File.read(File.join(other, "HEAD")))
          native.object_format.should eq(selected)
          native.bare?.should eq(bare)
          native.head.should eq(Git::References::Ref.new("HEAD", nil, "refs/heads/main"))
          GitOracle.run(root, "rev-parse", "--is-bare-repository").stdout.strip.should eq(bare.to_s)
          GitOracle.run(root, "symbolic-ref", "HEAD").stdout.strip.should eq("refs/heads/main")
          sig = Git::Signature.new("Writer", "writer@example.invalid", 1_700_000_000_i64, 0)
          if bare
            tree = native.write_tree([] of Git::Tree::Entry)
            oid = native.write_commit(tree: tree, author: sig, committer: sig, message: "bare\n")
            native.refs.update("refs/heads/main", oid, expected_oid: nil)
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(oid)
          else
            native.stage_file("hello.txt")
            oid = native.commit(author: sig, committer: sig, message: "initial\n")
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(oid)
            GitOracle.run(root, "ls-tree", "-r", "HEAD").stdout.should contain("hello.txt")
          end
          native.revalidate!
        ensure
          FileUtils.rm_rf(base)
        end
      end
    end
  end

  it "P22-O02 refuses malformed branches, existing metadata, nonempty bare roots and symlinks" do
    base = File.tempname("git-native-init-refusal", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(base)
    begin
      root = File.join(base, "root")
      Dir.mkdir(root)
      ["-bad", "../outside", "trailing.lock", "space name", "", "topic//other"].each do |branch|
        expect_raises(Git::Error, /initial branch/) { Git::Repository.init(root, initial_branch: branch) }
      end
      File.exists?(File.join(root, ".git")).should be_false
      Git::Repository.init(root)
      before = File.read(File.join(root, ".git", "HEAD"))
      expect_raises(Git::Error, /already exists/) { Git::Repository.init(root) }
      File.read(File.join(root, ".git", "HEAD")).should eq(before)
      expect_raises(Git::Error, /empty directory/) { Git::Repository.init(root, bare: true) }
      other = File.join(base, "other")
      Dir.mkdir(other)
      File.write(File.join(other, "protected"), "safe")
      File.symlink(other, File.join(base, "alias"))
      expect_raises(Git::Error) { Git::Repository.init(File.join(base, "alias")) }
      File.read(File.join(other, "protected")).should eq("safe")
      none = File.join(base, "missing")
      expect_raises(Git::Error, /existing/) { Git::Repository.init(none) }
      stale = File.join(base, "stale")
      Dir.mkdir(stale)
      File.symlink(other, File.join(stale, ".git"))
      expect_raises(Git::Error, /already exists/) { Git::Repository.init(stale) }
      File.read(File.join(other, "protected")).should eq("safe")
    ensure
      FileUtils.rm_rf(base)
    end
  end
end

describe "P10 native Git full commit-history traversal" do
  ["sha1", "sha256"].each do |format|
    it "P10-O01 traverses the #{format} merge DAG in child-before-parent order" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", "base")
        GitOracle.run(root, "commit", "-qm", "base")
        baseline = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "-b", "side")
        File.write(File.join(root, "side"), "side\n")
        GitOracle.run(root, "add", "side")
        GitOracle.run(root, "commit", "-qm", "side")
        side = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", "main")
        GitOracle.run(root, "commit", "-qm", "main")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "merge", "-q", "--no-ff", "-m", "merge", "side")
        merged = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "tag", "-a", "v1", "-m", "release")

        repository = Git::Repository.new(root)
        result = repository.history
        result.scanned.should eq(4)
        result.truncated.should be_false
        result.commits.map(&.oid).to_set.should eq([baseline, side, main, merged].to_set)
        result.commits.first.oid.should eq(merged)
        index = {} of String => Int32
        result.commits.each_with_index { |commit, i| index[commit.oid] = i }
        result.commits.each do |commit|
          commit.parents.each { |parent| index[commit.oid].should be < index[parent] }
        end
        GitOracle.run(root, "rev-list", "--all", "--count").stdout.strip.should eq(result.scanned.to_s)
        abbreviated = repository.history(["HEAD"], limit: 2)
        abbreviated.truncated.should be_true
        abbreviated.commits.size.should eq(2)
        abbreviated.scanned.should eq(4)
        repository.history(["refs/tags/v1"]).commits.first.oid.should eq(merged)
        repository.history(["refs/heads/side"]).commits.map(&.oid).should eq([side, baseline])
        repository.history([main]).commits.map(&.oid).should eq([main, baseline])
        repository.history(["refs/heads/main", "refs/heads/side"]).scanned.should eq(4)
        expect_raises(Git::Error, /node budget/) { repository.history(max_nodes: 2) }
        expect_raises(Git::Error, /revision/) { repository.history(["--all"]) }
        expect_raises(Git::Error, /resolved/) { repository.history(["refs/heads/missing"]) }
        expect_raises(Git::Error, /not available/) { repository.history(["0" * repository.object_format.hexsize]) }
      end
    end

    it "P10-O02 reports unborn #{format} HEAD and fails closed on dangling parents" do
      base = File.tempname("git-native-unborn", dir: File.realpath(Dir.tempdir))
      Dir.mkdir_p(base)
      begin
        repository = Git::Repository.init(base,
          object_format: format == "sha256" ? Git::ObjectId::Format::SHA256 : Git::ObjectId::Format::SHA1)
        repository.history.scanned.should eq(0)
        repository.history.commits.should be_empty
        signature = Git::Signature.new("Writer", "writer@example.invalid", 1_700_000_000_i64, 0)
        tree = repository.write_tree([] of Git::Tree::Entry)
        missing = "a" * repository.object_format.hexsize
        commit = repository.write_commit(tree: tree, parents: [missing], author: signature,
          committer: signature, message: "dangling")
        expect_raises(Git::Error, /not available/) { repository.history([commit]) }
      ensure
        FileUtils.rm_rf(base)
      end
    end
  end
end

describe "P22 create-only native branch and tag operations" do
  ["sha1", "sha256"].each do |format|
    it "P22-O03 creates #{format} branches and lightweight/annotated tags" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "initial"), "initial\n")
        GitOracle.run(root, "add", "initial")
        GitOracle.run(root, "commit", "-qm", "initial")
        old = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        repo.branches.create("topic/nested").should eq(old)
        GitOracle.run(root, "rev-parse", "refs/heads/topic/nested").stdout.strip.should eq(old)
        repo.head.symref_target.should eq("refs/heads/main")
        repo.tags.create("v1").should eq(old)
        GitOracle.run(root, "rev-parse", "refs/tags/v1").stdout.strip.should eq(old)
        sig = Git::Signature.new("Tagger", "tagger@example.invalid", 1_700_000_000_i64, 0)
        annotated = repo.tags.create("v2", from: "refs/heads/topic/nested", message: "Release\n", tagger: sig)
        GitOracle.run(root, "cat-file", "-t", annotated).stdout.strip.should eq("tag")
        GitOracle.run(root, "rev-parse", "refs/tags/v2^{}").stdout.strip.should eq(old)
        repo.history(["refs/tags/v2"]).commits.first.oid.should eq(old)
        repo.branches.create("from-tag", from: "refs/tags/v2").should eq(old)
        bad = repo.write_tag(object: old, type: "tag", name: "bad", tagger: sig, message: "bad type\n")
        repo.refs.update("refs/tags/bad", bad, expected_oid: nil)
        expect_raises(Git::Error, /target type mismatch/) { repo.history(["refs/tags/bad"]) }
        expect_raises(Git::Error, /compare-and-swap/) { repo.branches.create("topic/nested") }
        expect_raises(Git::Error, /compare-and-swap/) { repo.tags.create("v1") }
        expect_raises(Git::Error, /branch name/) { repo.branches.create("-force") }
        expect_raises(Git::Error, /tag name/) { repo.tags.create("../wrong") }
        expect_raises(Git::Error, /both tagger and message/) { repo.tags.create("v3", message: "message") }
        repo.head.oid.should eq(old)
      end
    end
  end
end
