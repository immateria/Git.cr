require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

module EolWorkflowSupport
  def self.commit(repository : Git::Repository, text : String, attrs : String?, parents = [] of String) : String
    entries = [Git::Tree::Entry.new("file.txt", "100644", repository.write_blob(text))]
    entries << Git::Tree::Entry.new(".gitattributes", "100644", repository.write_blob(attrs)) if attrs
    signature = Git::Signature.new("EOL Workflows", "eol@example.invalid", 1_700_000_000_i64, 0)
    repository.write_commit(tree: repository.write_tree(entries), parents: parents,
      author: signature, committer: signature, message: "fixture")
  end

  def self.pair(root : String, *, same : Bool = false, target_attributes : String = "*.txt text eol=lf\n") : {Git::Repository, String, String}
    repository = Git::Repository.new(root)
    first = commit(repository, "first\n", "*.txt text eol=crlf\n")
    tip = commit(repository, same ? "first\n" : "second\n", target_attributes, [first])
    repository.refs.update("refs/heads/main", first, expected_oid: nil)
    repository.refs.update("refs/heads/topic", tip, expected_oid: nil)
    repository.stage_blob("file.txt", "first\n")
    repository.stage_blob(".gitattributes", "*.txt text eol=crlf\n")
    File.write(File.join(root, "file.txt"), "first\r\n")
    File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
    {repository, first, tip}
  end
end

describe "shared EOL workflow support" do
  ["sha1", "sha256"].each do |format|
    it "records actual #{format} output bytes while validating canonical receipt IDs" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        canonical = repository.write_blob("canonical\n")
        write = Git::Checkout::Write.new("file.txt", "100644", canonical, "canonical\r\n")
        raw = Git::Merge::Recovery.encode([] of String, [write], canonical, canonical,
          repository.object_format, 4096, 10)
        receipt = Git::Merge::Recovery.decode(raw, canonical, canonical, repository.object_format, 4096, 10)
        receipt.outputs["file.txt"].oid.should eq(Git::ObjectId.digest("blob", write.data, repository.object_format))
        expect_raises(Git::Error) do
          Git::Merge::Recovery.encode([] of String,
            [Git::Checkout::Write.new("file.txt", "100644", "invalid", write.data)],
            canonical, canonical, repository.object_format, 4096, 10)
        end
      end
    end

    it "fast-forwards clean #{format} CRLF bytes and materializes target attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository, first, tip = EolWorkflowSupport.pair(root)
        result = repository.fast_forward("topic")
        result.previous_oid.should eq(first)
        result.target_oid.should eq(tip)
        File.read(File.join(root, "file.txt")).should eq("second\n")
        repository.index_entries.find { |entry| entry.path == "file.txt" }.not_nil!.oid.should eq(repository.write_blob("second\n"))
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "leaves canonical-unchanged #{format} files alone despite stale stats and new attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, _ = EolWorkflowSupport.pair(root, same: true)
        result = repository.fast_forward("topic")
        result.changed_paths.should eq([".gitattributes"])
        File.read(File.join(root, "file.txt")).should eq("first\r\n")
      end
    end
  end
end

describe "planned workflow conversion" do
  ["sha1", "sha256"].each do |format|
    it "projects #{format} ours stages, explicit deletion, and absent-only working attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        crlf = repository.write_blob("*.txt text eol=crlf\n")
        lf = repository.write_blob("*.txt text eol=lf\n")
        File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
        Dir.mkdir_p(File.join(root, "new"))
        File.write(File.join(root, "new", ".gitattributes"), "*.txt text eol=crlf\n")
        current = [Git::Index::Entry.new(".gitattributes", "100644", lf, 0, false, false),
                   Git::Index::Entry.new("nested/.gitattributes", "100644", lf, 3, false, false),
                   Git::Index::Entry.new("nested/.gitattributes", "100644", crlf, 2, false, false)]
        converter = Git::Conversion.for_index(repository, current)
        converter.checkout("file.txt", "x\n").should eq("x\n")
        converter.checkout("nested/file.txt", "x\n").should eq("x\r\n")
        converter.checkout("new/file.txt", "x\n").should eq("x\r\n")
        converter = Git::Conversion.for_index(repository, current,
          edits: [Git::Index::Remove.new(".gitattributes"), Git::Index::InvalidateStat.new("nested/.gitattributes")] of Git::Index::Edit)
        converter.checkout("file.txt", "x\n").should eq("x\n")
        converter.checkout("nested/file.txt", "x\n").should eq("x\r\n")
        stages = [Git::Index::Entry.new("new/.gitattributes", "100644", crlf, 3, false, false)]
        converter = Git::Conversion.for_index(repository, [] of Git::Index::Entry,
          edits: [Git::Index::PutStages.new("new/.gitattributes", stages),
                  Git::Index::Put.new(".gitattributes", "120000", crlf)] of Git::Index::Edit)
        converter.checkout("new/file.txt", "x\n").should eq("x\n")
        expect_raises(ArgumentError) { Git::Conversion.new(repository, worktree_fallback: true) }
        expect_raises(ArgumentError) { Git::Attributes.new(repository, worktree_fallback: true) }
        exact = Git::Conversion.new(repository, attribute_blobs: {} of String => String?)
        exact.checkout("new/file.txt", "x\n").should eq("x\n")
      end
    end

    it "uses actual #{format} marker bytes and final relocated rule paths without publication" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        lf = repository.write_blob("*.txt text eol=lf\n")
        marker = "<<<<<<< ours\n*.txt text eol=lf\n=======\nfile.txt~ours text eol=crlf\n>>>>>>> theirs\n"
        marker_oid = Git::ObjectId.digest("blob", marker, repository.object_format)
        expect_raises(Git::Error) { repository.read_object(marker_oid, max_bytes: 4096) }
        before = Dir.children(root).sort
        current = [Git::Index::Entry.new("nested/.gitattributes", "100644", lf, 2, false, false)]
        converter = Git::Conversion.for_index(repository, current,
          edits: [Git::Index::Put.new("nested/.gitattributes", "100644", lf)] of Git::Index::Edit,
          writes: [Git::Checkout::Write.new("nested/.gitattributes", "100644", lf, marker)])
        converter.checkout("nested/file.txt~ours", "x\n").should eq("x\r\n")
        converter.checkout("nested/file.txt", "x\n").should eq("x\n")
        repository.read_object(marker_oid, max_bytes: 4096).data.should eq(marker)
        Dir.children(root).sort.should eq(before)
        repository.index_entries.should be_empty
      end
    end

    it "preserves canonical #{format} write IDs, projects raw states, and keeps symlinks raw" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        attrs = repository.write_blob("* text eol=crlf\n")
        oid = repository.write_blob("x\n")
        converter = Git::Conversion.new(repository, attribute_blobs: {".gitattributes" => attrs.as(String?)})
        writes = [Git::Checkout::Write.new("file.txt", "100755", oid, "x\n"),
                  Git::Checkout::Write.new("link", "120000", oid, "x\n")]
        output = converter.materialize(writes, max_total_bytes: 5_i64)
        output[0].should eq(Git::Checkout::Write.new("file.txt", "100755", oid, "x\r\n"))
        output[1].should eq(writes[1])
        writes[0].data.should eq("x\n")
        states = {"file.txt" => Git::Checkout::FileState.new("100755", oid), "link" => Git::Checkout::FileState.new("120000", oid)}
        raw = converter.raw_states(states, max_total_bytes: 5_i64)
        raw["file.txt"].should eq(Git::Checkout::FileState.new("100755", Git::ObjectId.digest("blob", "x\r\n", repository.object_format)))
        raw["link"].should eq(states["link"])
        states["file.txt"].oid.should eq(oid)
        expect_raises(Git::Error, /byte budget/) { converter.materialize(writes, max_total_bytes: 4_i64) }
        expect_raises(Git::Error, /byte budget/) { converter.raw_states(states, max_total_bytes: 4_i64) }
      end
    end
  end

  it "rejects expansion, invalid paths/modes and cancellation before any publication" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      attrs = repository.write_blob("* text eol=crlf\n")
      oid = repository.write_blob("\n" * 20)
      blobs = {".gitattributes" => attrs.as(String?)}
      converter = Git::Conversion.new(repository, attribute_blobs: blobs, max_bytes: 32)
      write = Git::Checkout::Write.new("file", "100644", oid, "\n" * 20)
      expect_raises(Git::Error, /byte budget/) { converter.materialize([write], max_total_bytes: 100_i64) }
      states = {"file" => Git::Checkout::FileState.new("100644", oid)}
      expect_raises(Git::Error, /byte budget/) { converter.raw_states(states, max_total_bytes: 100_i64) }
      [Git::Checkout::Write.new("../escape", "100644", oid, "x"),
       Git::Checkout::Write.new("file", "160000", oid, "x")].each do |invalid|
        expect_raises(Git::Error) { converter.materialize([invalid], max_total_bytes: 100_i64) }
        expect_raises(Git::Error) { converter.raw_states({invalid.path => Git::Checkout::FileState.new(invalid.mode, invalid.oid)}, max_total_bytes: 100_i64) }
      end
      cancelled = false
      check = -> { raise Git::Error.new("cancelled") if cancelled }
      converter = Git::Conversion.new(repository, attribute_blobs: blobs, check: check)
      cancelled = true
      expect_raises(Git::Error, "cancelled") { converter.materialize([write], max_total_bytes: 100_i64) }
      expect_raises(Git::Error, "cancelled") { converter.raw_states(states, max_total_bytes: 100_i64) }
      expect_raises(Git::Error, "cancelled") { Git::Conversion.for_index(repository, [] of Git::Index::Entry, check: check) }
      File.exists?(File.join(root, "file")).should be_false
      repository.index_entries.should be_empty
    end
  end
end

describe "clean-only reset publication" do
  ["sha1", "sha256"].each do |format|
    it "expands changed #{format} files using target rules" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, tip = EolWorkflowSupport.pair(root, target_attributes: "*.txt text eol=crlf\n")
        repository.fast_forward("topic").target_oid.should eq(tip)
        File.read(File.join(root, "file.txt")).should eq("second\r\n")
        repository.read_head_file("file.txt").should eq("second\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "refuses a clean-equivalent #{format} raw race at publication" do
      GitOracle.with_repo(format: format) do |root|
        repository, first, _ = EolWorkflowSupport.pair(root, target_attributes: "*.txt text eol=crlf\n")
        raced = false
        check = -> do
          if !raced && File.exists?(File.join(root, ".git", "index.lock"))
            raced = true
            File.write(File.join(root, "file.txt"), "first\n")
          end
        end
        expect_raises(Git::Reset::PartialPublication) { repository.fast_forward("topic", check: check) }
        raced.should be_true
        repository.head.oid.should eq(first)
        File.read(File.join(root, "file.txt")).should eq("first\n")
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end
  end
end

describe "workflow helper bounds" do
  it "bounds attribute marker writes before interpreting their canonical ID" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      marker = "* text eol=crlf\n" * 4
      oid = repository.write_blob("* text eol=lf\n")
      writes = [Git::Checkout::Write.new(".gitattributes", "100644", oid, marker)]
      expect_raises(Git::Error, /byte budget/) do
        Git::Conversion.for_index(repository, [] of Git::Index::Entry, writes: writes, max_bytes: 32)
      end
      File.exists?(File.join(root, ".gitattributes")).should be_false
      repository.index_entries.should be_empty
    end
  end

  it "bounds canonical reads and raw symlink bytes and propagates operation labels" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      oid = repository.write_blob("12345")
      converter = Git::Conversion.new(repository, attribute_blobs: {} of String => String?, max_bytes: 4)
      link = Git::Checkout::Write.new("link", "120000", oid, "12345")
      expect_raises(Git::Error, /byte budget/) { converter.materialize([link], max_total_bytes: 10_i64) }
      converter = Git::Conversion.new(repository, attribute_blobs: {} of String => String?)
      states = {"file" => Git::Checkout::FileState.new("100644", oid)}
      expect_raises(Git::Error, /test restore total read byte budget/) do
        converter.raw_states(states, max_total_bytes: 4_i64, operation: "test restore")
      end
      expect_raises(Git::Error, /test restore total byte budget/) do
        converter.materialize([link], max_total_bytes: 4_i64, operation: "test restore")
      end
    end
  end
end
