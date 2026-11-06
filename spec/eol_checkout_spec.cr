require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

module EolCheckoutFixture
  LF   = "*.txt text eol=lf\n"
  CRLF = "*.txt text eol=crlf\n"

  def self.commit(repository : Git::Repository, text : String, attributes : String?,
                  parents : Array(String) = [] of String) : String
    entries = [Git::Tree::Entry.new("file.txt", "100644", repository.write_blob(text))]
    if attributes
      entries << Git::Tree::Entry.new(".gitattributes", "100644", repository.write_blob(attributes))
    end
    signature = Git::Signature.new("EOL Checkout", "eol-checkout@example.invalid", 1_700_000_000_i64, 0)
    repository.write_commit(tree: repository.write_tree(entries), parents: parents,
      author: signature, committer: signature, message: "fixture")
  end

  def self.install(repository : Git::Repository, oid : String, text : String, attributes : String?,
                   raw_text : String? = nil) : Nil
    repository.refs.update("refs/heads/main", oid, expected_oid: nil)
    repository.stage_blob("file.txt", text)
    File.write(File.join(repository.root, "file.txt"), raw_text || text)
    if attributes
      repository.stage_blob(".gitattributes", attributes)
      File.write(File.join(repository.root, ".gitattributes"), attributes)
    end
  end

  def self.pair(root : String, first_attributes : String = LF, next_attributes : String = CRLF,
                first_text : String = "first\n", next_text : String = "second\n",
                first_raw : String? = nil) : {Git::Repository, String, String}
    repository = Git::Repository.new(root)
    first = commit(repository, first_text, first_attributes)
    tip = commit(repository, next_text, next_attributes, [first])
    install(repository, first, first_text, first_attributes, first_raw)
    repository.refs.update("refs/heads/topic", tip, expected_oid: nil)
    {repository, first, tip}
  end

  def self.conflict_attributes(repository : Git::Repository, path : String,
                               ours : String = CRLF) : Nil
    stages = String.build do |io|
      io << "0 " << Git::ObjectId.zero(repository.object_format) << '\t' << path << '\n'
      [LF, ours, "*.txt -text\n"].each_with_index do |attributes, index|
        io << "100644 " << repository.write_blob(attributes) << ' ' << index + 1 << '\t' << path << '\n'
      end
    end
    GitOracle.run(repository.root, "update-index", "--index-info", input: stages)
  end
end

describe "native checkout text/EOL conversion" do
  ["sha1", "sha256"].each do |format|
    it "uses target attributes for changed #{format} blobs and accepts clean CRLF predecessors" do
      GitOracle.with_repo(format: format) do |root|
        repository, first, tip = EolCheckoutFixture.pair(root)
        repository.switch("topic").commit_oid.should eq(tip)
        File.read(File.join(root, "file.txt")).should eq("second\r\n")
        repository.read_head_file("file.txt").should eq("second\n")
        repository.working_changes.should be_empty
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repository.switch("main").commit_oid.should eq(first)
        File.read(File.join(root, "file.txt")).should eq("first\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "leaves an unchanged #{format} file untouched when only its attributes change" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, _ = EolCheckoutFixture.pair(root, first_text: "same\n", next_text: "same\n")
        repository.switch("topic").changed_paths.should eq([".gitattributes"])
        File.read(File.join(root, "file.txt")).should eq("same\n")
        repository.diff.to_s.should eq("")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "restores #{format} content with index attributes and overlays selected source attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository, first, tip = EolCheckoutFixture.pair(root)
        repository.switch("topic")
        index_before = File.read(File.join(root, ".git", "index"))
        File.write(File.join(root, "file.txt"), "dirty\n")
        repository.restore(["file.txt"], source: first)
        File.read(File.join(root, "file.txt")).should eq("first\r\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolCheckoutFixture::CRLF)
        File.write(File.join(root, "file.txt"), "dirty again\n")
        repository.restore([".gitattributes", "file.txt"], source: first)
        File.read(File.join(root, "file.txt")).should eq("first\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolCheckoutFixture::LF)
        File.read(File.join(root, ".git", "index")).should eq(index_before)
        repository.head.oid.should eq(tip)
      end
    end

    it "restores #{format} files despite unrelated conflicted attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        first = EolCheckoutFixture.commit(repository, "restored\n", EolCheckoutFixture::CRLF)
        EolCheckoutFixture.install(repository, first, "restored\n", EolCheckoutFixture::CRLF)
        EolCheckoutFixture.conflict_attributes(repository, "unrelated/.gitattributes")
        path = File.join(root, "file.txt")
        File.write(path, "dirty\n")
        index_before = File.read(File.join(root, ".git", "index"))
        GitOracle.run(root, "restore", "--source=HEAD", "--", "file.txt")
        expected = File.read(path)
        expected.should eq("restored\r\n")
        File.write(path, "dirty\n")
        repository.restore(["file.txt"]).should eq(["file.txt"])
        File.read(path).should eq(expected)
        File.read(File.join(root, ".git", "index")).should eq(index_before)
        repository.head.oid.should eq(first)
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end

    it "uses ours-stage #{format} ancestor attributes when restoring an unmerged attribute tree" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        repository.stage_blob(".gitattributes", EolCheckoutFixture::LF)
        repository.stage_blob("nested/file.txt", "restored\n")
        signature = Git::Signature.new("EOL Checkout", "eol-checkout@example.invalid", 1_700_000_000_i64, 0)
        first = repository.commit(author: signature, committer: signature, message: "fixture")
        EolCheckoutFixture.conflict_attributes(repository, "nested/.gitattributes")
        File.write(File.join(root, ".gitattributes"), EolCheckoutFixture::LF)
        Dir.mkdir(File.join(root, "nested"))
        path = File.join(root, "nested", "file.txt")
        File.write(path, "dirty\n")
        index_before = File.read(File.join(root, ".git", "index"))
        GitOracle.run(root, "restore", "--source=HEAD", "--", "nested/file.txt")
        expected = File.read(path)
        expected.should eq("restored\r\n")
        File.write(path, "dirty\n")
        repository.restore(["nested/file.txt"]).should eq(["nested/file.txt"])
        File.read(path).should eq(expected)
        File.read(File.join(root, ".git", "index")).should eq(index_before)
        repository.head.oid.should eq(first)
      end
    end

    it "refuses explicitly selected conflicted #{format} attribute paths before publication" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        first = EolCheckoutFixture.commit(repository, "restored\n", EolCheckoutFixture::CRLF)
        EolCheckoutFixture.install(repository, first, "restored\n", EolCheckoutFixture::CRLF)
        EolCheckoutFixture.conflict_attributes(repository, ".gitattributes")
        path = File.join(root, "file.txt")
        File.write(path, "dirty\n")
        index_before = File.read(File.join(root, ".git", "index"))
        expect_raises(Git::Error, /resolved/) { repository.restore(["file.txt", ".gitattributes"]) }
        File.read(path).should eq("dirty\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolCheckoutFixture::CRLF)
        File.read(File.join(root, ".git", "index")).should eq(index_before)
        repository.head.oid.should eq(first)
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end

    it "uses the target #{format} attributes for hard reset without changing stored blob bytes" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, tip = EolCheckoutFixture.pair(root)
        File.write(File.join(root, "file.txt"), "dirty\r\n")
        repository.reset("topic", mode: Git::Reset::Mode::Hard)
        repository.head.oid.should eq(tip)
        File.read(File.join(root, "file.txt")).should eq("second\r\n")
        repository.read_head_file("file.txt").should eq("second\n")
        repository.working_changes.should be_empty
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "populates a native #{format} clone from tree attributes absent from the source worktree" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        tip = EolCheckoutFixture.commit(repository, "copied\n", EolCheckoutFixture::CRLF)
        repository.refs.update("refs/heads/main", tip, expected_oid: nil)
        File.exists?(File.join(root, ".gitattributes")).should be_false
        destination = File.join(File.dirname(root), "eol-clone")
        cloned = Git::Repository.clone(root, destination)
        File.read(File.join(destination, "file.txt")).should eq("copied\r\n")
        cloned.read_head_file("file.txt").should eq("copied\n")
        cloned.working_changes.should be_empty
        GitOracle.run(destination, "status", "--porcelain").stdout.should eq("")
      end
    end
  end

  it "uses explicitly selected autocrlf configuration during clone checkout" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      tip = EolCheckoutFixture.commit(repository, "configured\n", nil)
      repository.refs.update("refs/heads/main", tip, expected_oid: nil)
      config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
      destination = File.join(File.dirname(root), "configured-clone")
      cloned = Git::Repository.clone(root, destination, config: config)
      File.read(File.join(destination, "file.txt")).should eq("configured\r\n")
      cloned.working_changes(config: config).should be_empty
      GitOracle.run(destination, "-c", "core.autocrlf=true", "status", "--porcelain").stdout.should eq("")
    end
  end

  it "rejects checkout expansion beyond the byte limit before publication" do
    GitOracle.with_repo do |root|
      repository, first, _ = EolCheckoutFixture.pair(root,
        first_attributes: EolCheckoutFixture::CRLF, next_attributes: EolCheckoutFixture::CRLF,
        next_text: "a\n" * 180, first_raw: "first\r\n")
      index_before = File.read(File.join(root, ".git", "index"))
      expect_raises(Git::Error, /budget/) { repository.switch("topic", max_blob_bytes: 384) }
      repository.head.oid.should eq(first)
      File.read(File.join(root, "file.txt")).should eq("first\r\n")
      File.read(File.join(root, ".git", "index")).should eq(index_before)
      File.exists?(File.join(root, ".git", "index.lock")).should be_false
    end
  end

  it "preserves a concurrent EOL-only worktree change through its raw publication guard" do
    GitOracle.with_repo do |root|
      repository, first, _ = EolCheckoutFixture.pair(root,
        first_attributes: EolCheckoutFixture::CRLF, next_attributes: EolCheckoutFixture::CRLF,
        first_raw: "first\r\n")
      index_before = File.read(File.join(root, ".git", "index"))
      altered = false
      callback = -> do
        if !altered && File.exists?(File.join(root, ".git", "HEAD.lock"))
          File.write(File.join(root, "file.txt"), "first\n")
          altered = true
        end
        nil
      end
      error = expect_raises(Git::Checkout::PartialPublication) { repository.switch("topic", check: callback) }
      altered.should be_true
      error.changed_paths.should be_empty
      repository.head.oid.should eq(first)
      File.read(File.join(root, "file.txt")).should eq("first\n")
      File.read(File.join(root, ".git", "index")).should eq(index_before)
    end
  end

  ["restore", "reset"].each do |operation|
    it "#{operation} retains stat-clean bytes and converts stat-dirty identical content" do
      GitOracle.with_repo do |root|
        repository = Git::Repository.new(root)
        first = EolCheckoutFixture.commit(repository, "same\n", nil)
        EolCheckoutFixture.install(repository, first, "same\n", nil)
        path = File.join(root, "file.txt")
        File.touch(path, Time.unix(1_600_000_000))
        repository.stage_file("file.txt")
        File.open(File.join(root, ".git", "config"), "a") { |io| io << "\n[core]\n\tautocrlf = true\n" }
        if operation == "restore"
          repository.restore(["file.txt"])
        else
          repository.reset(mode: Git::Reset::Mode::Hard)
        end
        File.read(path).should eq("same\n")
        File.write(path, "same\n")
        if operation == "restore"
          repository.restore(["file.txt"])
        else
          repository.reset(mode: Git::Reset::Mode::Hard)
        end
        File.read(path).should eq("same\r\n")
        repository.working_changes(include_untracked: false).should be_empty
        repository.diff.to_s.should eq("")
        GitOracle.run(root, "diff", "--exit-code").success?.should be_true
        # Like `git restore --source=HEAD`, worktree-only restore preserves
        # the index's old stat size; Git's porcelain then reports a stat edit.
        expected_status = operation == "restore" ? " M file.txt\n" : ""
        GitOracle.run(root, "status", "--porcelain").stdout.should eq(expected_status)
      end
    end
  end
end
