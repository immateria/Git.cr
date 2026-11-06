require "spec"
require "../src/git"
require "./support/merge_partial_recovery"

describe "Git worktree recovery receipt authority" do
  MergePartialRecoverySpec::OPERATIONS.each do |operation|
    it "refuses #{operation} recovery metadata changed before the first worktree publication" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, true)
        name = operation == "merge" ? "CRYSTAL_MERGE_PATHS" : "CRYSTAL_SEQUENCER_PATHS"
        receipt_path = File.join(root, ".git", name)
        saved = nil.as(String?)
        before_publication_index = original[1]
        check = -> do
          if saved.nil? && File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation)))
            before_publication_index = GitOracle.run(root, "ls-files", "-s").stdout
            saved = File.read(receipt_path)
            File.write(receipt_path, "../unrelated")
          end
        end
        if operation == "merge"
          error = expect_raises(Git::Merge::PartialPublication) do
            MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
          end
          error.index_published.should be_false
          error.changed_paths.should be_empty
          error.original_error.message.should match(/recovery metadata changed/)
        else
          error = expect_raises(Git::Sequencer::PartialPublication) do
            MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
          end
          error.index_published.should be_false
          error.changed_paths.should be_empty
          error.original_error.message.should match(/recovery metadata changed/)
        end
        File.read(File.join(root, "node")).should eq("changed\n")
        GitOracle.run(root, "ls-files", "-s").stdout.should eq(before_publication_index)
        expect_raises(Git::Error) { MergePartialRecoverySpec.abort(Git::Repository.new(root), operation) }
        File.write(receipt_path, saved.not_nil!)
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end
  end
end

describe "Git bounded recovery receipt format" do
  ours = "a" * 40
  theirs = "b" * 40
  format = Git::ObjectId::Format::SHA1

  it "supports receipts above 64 KiB within the index budget" do
    writes = (0...2000).map { |i| Git::Checkout::Write.new("file-#{i}", "100644", "c" * 40, "") }
    raw = Git::Merge::Recovery.encode([] of String, writes, ours, theirs, format, 262_144, 2000)
    raw.bytesize.should be > 65_536
    receipt = Git::Merge::Recovery.decode(raw, ours, theirs, format, 262_144, 2000)
    receipt.outputs.size.should eq(2000)
    expect_raises(Git::Error, /budget/) do
      Git::Merge::Recovery.decode(raw, ours, theirs, format, 65_536, 2000)
    end
  end

  it "keeps raw non-UTF-8 path bytes and validates operation identity" do
    path = "file-" + String.new(Bytes[0xff])
    writes = [Git::Checkout::Write.new(path, "120000", "c" * 40, "target")]
    raw = Git::Merge::Recovery.encode([path], writes, ours, theirs, format, 1024, 10)
    receipt = Git::Merge::Recovery.decode(raw, ours, theirs, format, 1024, 10)
    receipt.paths.first.to_slice.should eq(path.to_slice)
    receipt.outputs[path].mode.should eq("120000")
    expect_raises(Git::Error, /identity/) do
      Git::Merge::Recovery.decode(raw, theirs, ours, format, 1024, 10)
    end
  end

  it "rejects malformed records and duplicate output authority" do
    cases = [
      {1, ["file", "100644"].join('\0')},
      {1, ["../outside", "100644", "c" * 40].join('\0')},
      {1, ["file", "160000", "c" * 40].join('\0')},
      {2, ["file", "100644", "c" * 40, "file", "100644", "c" * 40].join('\0')},
    ]
    cases.each do |count, records|
      header = Git::Merge::Recovery::MAGIC + [ours, theirs, "0", count.to_s].join('\0')
      expect_raises(Git::Error) do
        Git::Merge::Recovery.decode(header + "\0" + records, ours, theirs, format, 1024, 10)
      end
    end
  end
end

describe "Git recovery metadata file kinds" do
  it "rejects a FIFO receipt without waiting for a writer" do
    GitOracle.with_repo do |root|
      path = File.join(root, ".git", "recovery-probe")
      LibC.mkfifo(path, 0o600).should eq(0)
      admin = Git::DescriptorPath::Directory.open(File.join(root, ".git"))
      begin
        expect_raises(Git::Error, /not regular/) do
          Git::Merge::Recovery.read(admin, "recovery-probe", 1024)
        end
      ensure
        admin.close
      end
    end
  end
end

describe "Git required worktree recovery receipts" do
  MergePartialRecoverySpec::OPERATIONS.each do |operation|
    it "keeps #{operation} partial state when its required receipt is missing" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, false)
        check = -> do
          if Dir.children(root).any?(&.starts_with?("node~"))
            raise Git::Error.new("injected recovery failure")
          end
        end
        MergePartialRecoverySpec.expect_partial(operation) do
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
        end
        relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
        contents = File.read(File.join(root, relocated))
        name = operation == "merge" ? "CRYSTAL_MERGE_PATHS" : "CRYSTAL_SEQUENCER_PATHS"
        path = File.join(root, ".git", name)
        receipt = File.read(path)
        File.delete(path)
        expect_raises(Git::Error) { MergePartialRecoverySpec.abort(Git::Repository.new(root), operation) }
        File.read(File.join(root, relocated)).should eq(contents)
        File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation))).should be_true
        File.write(path, receipt)
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end
  end
end

describe "Git recovery receipt truncation" do
  MergePartialRecoverySpec::OPERATIONS.each do |operation|
    ["empty", "legacy-looking"].each do |replacement|
      it "preserves #{operation} unpublished outputs when a required receipt becomes #{replacement}" do
        GitOracle.with_repo do |root|
          original = MergePartialRecoverySpec.fixture(root, operation, false)
          check = -> do
            raise Git::Error.new("injected recovery failure") if Dir.children(root).any?(&.starts_with?("node~"))
          end
          MergePartialRecoverySpec.expect_partial(operation) do
            MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
          end
          relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
          contents = File.read(File.join(root, relocated))
          name = operation == "merge" ? "CRYSTAL_MERGE_PATHS" : "CRYSTAL_SEQUENCER_PATHS"
          path = File.join(root, ".git", name)
          saved = File.read(path)
          File.write(path, replacement == "empty" ? "" : "unrelated")
          expect_raises(Git::Error) { MergePartialRecoverySpec.abort(Git::Repository.new(root), operation) }
          File.read(File.join(root, relocated)).should eq(contents)
          File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation))).should be_true
          File.write(path, saved)
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          MergePartialRecoverySpec.assert_restored(root, operation, original)
        end
      end
    end
  end

  it "rejects a receipt truncated at an output record boundary" do
    ours = "a" * 40
    theirs = "b" * 40
    format = Git::ObjectId::Format::SHA1
    writes = [Git::Checkout::Write.new("added", "100644", "c" * 40, "data")]
    raw = Git::Merge::Recovery.encode([] of String, writes, ours, theirs, format, 1024, 10)
    truncated = raw.split('\0')[0...-3].join('\0')
    expect_raises(Git::Error, /output count/) do
      Git::Merge::Recovery.decode(truncated, ours, theirs, format, 1024, 10)
    end
  end
end
