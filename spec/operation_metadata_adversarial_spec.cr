require "spec"
require "../src/git"
require "./support/git_oracle"

module OperationMetadataAdversarialSpec
  SIGNATURE = Git::Signature.new("Metadata", "metadata@example.test", 1234567890_i64, 0)

  def self.initial_commit(root : String) : String
    File.write(File.join(root, "tracked"), "tracked\n")
    GitOracle.run(root, "add", ".")
    GitOracle.run(root, "commit", "-qm", "initial")
    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
  end

  def self.merge_fixture(root : String, conflict : Bool = false) : {String, String}
    initial_commit(root)
    GitOracle.run(root, "checkout", "-qb", "topic")
    File.write(File.join(root, conflict ? "tracked" : "incoming"), "incoming\n")
    GitOracle.run(root, "add", ".")
    GitOracle.run(root, "commit", "-qm", "topic")
    theirs = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
    GitOracle.run(root, "checkout", "-q", "main")
    File.write(File.join(root, conflict ? "tracked" : "ours"), "ours\n")
    GitOracle.run(root, "add", ".")
    GitOracle.run(root, "commit", "-qm", "ours")
    File.write(File.join(root, "caller"), "preserve caller\n")
    {GitOracle.run(root, "rev-parse", "HEAD").stdout.strip, theirs}
  end

  def self.write_state(root : String, operation : String, name : String) : String
    oid = initial_commit(root)
    receipt = Git::Merge::Recovery.encode([] of String, [] of Git::Checkout::Write,
      oid, oid, Git::ObjectId::Format::SHA1, 1024, 10)
    directory = File.join(root, ".git")
    files = case operation
            when "merge"
              {"MERGE_HEAD" => "#{oid}\n", "CRYSTAL_MERGE_ORIG" => "refs/heads/main\n#{oid}\nworktree-v1\n",
               "CRYSTAL_MERGE_PATHS" => receipt, "MERGE_MSG" => "merge\n"}
            when "sequencer"
              head = {"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"}.includes?(name) ? name : "CHERRY_PICK_HEAD"
              {head => "#{oid}\n", "CRYSTAL_SEQUENCER_ORIG" => "refs/heads/main\n#{oid}\nworktree-v1\n",
               "CRYSTAL_SEQUENCER_PARENT" => "-\n", "CRYSTAL_SEQUENCER_AUTHOR" => "#{SIGNATURE.to_git_header}\n",
               "CRYSTAL_SEQUENCER_ALLOW_EMPTY" => "0\n", "CRYSTAL_SEQUENCER_PATHS" => receipt,
               "MERGE_MSG" => "pick\n"}
            else
              directory = File.join(directory, "rebase-merge")
              Dir.mkdir(directory)
              {"head-name" => "refs/heads/main\n", "orig-head" => "#{oid}\n", "upstream" => "#{oid}\n",
               "onto" => "#{oid}\n", "git-rebase-todo" => "", "state" => "next 0\nexpected #{oid}\nkeep-empty 0\n"}
            end
    files.each { |file, contents| File.write(File.join(directory, file), contents) }
    File.join(directory, name)
  end

  def self.reject_fifo(root : String, operation : String, name : String) : Nil
    path = write_state(root, operation, name)
    File.delete(path)
    LibC.mkfifo(path, 0o600).should eq(0)
    child = Process.new(Process.executable_path.not_nil!, [] of String,
      env: {"CR_GIT_OPERATION_FIFO_ROOT" => root, "CR_GIT_OPERATION_FIFO_KIND" => operation,
            "CR_GIT_OPERATION_FIFO_NAME" => name},
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    completion = Channel(Process::Status).new(1)
    spawn { completion.send(child.wait) }
    select
    when status = completion.receive
      status.exit_code.should eq(0)
    when timeout(2.seconds)
      child.terminate(graceful: false)
      completion.receive
      fail "#{operation} blocked while opening FIFO #{name} without a writer"
    end
    File.info(path, follow_symlinks: false).type.pipe?.should be_true
    File.read(File.join(root, "tracked")).should eq("tracked\n")
  end
end

# A child keeps a blocking FIFO regression from stranding the whole spec run.
if root = ENV["CR_GIT_OPERATION_FIFO_ROOT"]?
  begin
    repo = Git::Repository.new(root)
    case ENV["CR_GIT_OPERATION_FIFO_KIND"]
    when "merge"
      if ENV["CR_GIT_OPERATION_FIFO_NAME"] == "MERGE_MSG"
        repo.merge.continue(author: OperationMetadataAdversarialSpec::SIGNATURE,
          committer: OperationMetadataAdversarialSpec::SIGNATURE)
      else
        repo.merge.state?
      end
    when "sequencer"
      repo.sequencer.state?
    else
      repo.rebase.state?
    end
  rescue ex : Git::Error
    LibC._exit(ex.message.to_s.matches?(/not (a )?regular/) ? 0 : 2)
  end
  LibC._exit(3)
end

describe "Git operation metadata publication guards" do
  {"changed", "removed"}.each do |mutation|
    it "refuses a #{mutation} MERGE_HEAD before publishing the planned worktree or index" do
      GitOracle.with_repo do |root|
        ours, theirs = OperationMetadataAdversarialSpec.merge_fixture(root)
        before_index = File.read(File.join(root, ".git", "index"))
        injected = false
        check = -> do
          path = File.join(root, ".git", "MERGE_HEAD")
          if !injected && File.exists?(path)
            injected = true
            if mutation == "changed"
              File.write(path, "#{ours}\n")
            else
              File.delete(path)
            end
          end
        end
        error = expect_raises(Git::Merge::PartialPublication) do
          Git::Repository.new(root).merge("topic", author: OperationMetadataAdversarialSpec::SIGNATURE,
            committer: OperationMetadataAdversarialSpec::SIGNATURE, message: "merge", check: check)
        end
        injected.should be_true
        error.original_error.message.should match(/merge state changed/)
        error.changed_paths.should be_empty
        error.index_published.should be_false
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        File.read(File.join(root, ".git", "index")).should eq(before_index)
        File.exists?(File.join(root, "incoming")).should be_false
        File.read(File.join(root, "caller")).should eq("preserve caller\n")
        File.write(File.join(root, ".git", "MERGE_HEAD"), "#{theirs}\n")
        Git::Repository.new(root).merge.abort
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("?? caller\n")
      end
    end
  end

  it "refuses a changed MERGE_HEAD after a worktree write and keeps the original index" do
    GitOracle.with_repo do |root|
      ours, theirs = OperationMetadataAdversarialSpec.merge_fixture(root)
      before_index = File.read(File.join(root, ".git", "index"))
      injected = false
      check = -> do
        if !injected && File.exists?(File.join(root, "incoming"))
          injected = true
          File.write(File.join(root, ".git", "MERGE_HEAD"), "#{ours}\n")
        end
      end
      error = expect_raises(Git::Merge::PartialPublication) do
        Git::Repository.new(root).merge("topic", author: OperationMetadataAdversarialSpec::SIGNATURE,
          committer: OperationMetadataAdversarialSpec::SIGNATURE, message: "merge", check: check)
      end
      injected.should be_true
      error.original_error.message.should match(/merge state changed/)
      error.changed_paths.should eq(["incoming"])
      error.index_published.should be_false
      GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
      File.read(File.join(root, ".git", "index")).should eq(before_index)
      File.read(File.join(root, "incoming")).should eq("incoming\n")
      File.write(File.join(root, ".git", "MERGE_HEAD"), "#{theirs}\n")
      Git::Repository.new(root).merge.abort
      GitOracle.run(root, "status", "--porcelain").stdout.should eq("?? caller\n")
    end
  end
end

describe "Git merge continuation receipt identity" do
  ["sha1", "sha256"].each do |format|
    it "refuses rewritten #{format} MERGE_HEAD after conflict resolution" do
      GitOracle.with_repo(format: format) do |root|
        ours, theirs = OperationMetadataAdversarialSpec.merge_fixture(root, conflict: true)
        repo = Git::Repository.new(root)
        result = repo.merge("topic", author: OperationMetadataAdversarialSpec::SIGNATURE,
          committer: OperationMetadataAdversarialSpec::SIGNATURE, message: "merge")
        result.conflicts.should eq(["tracked"])
        File.write(File.join(root, "tracked"), "resolved\n")
        GitOracle.run(root, "add", "tracked")
        before_index = File.read(File.join(root, ".git", "index"))
        receipt = File.read(File.join(root, ".git", "CRYSTAL_MERGE_PATHS"))
        File.write(File.join(root, ".git", "MERGE_HEAD"), "#{ours}\n")
        expect_raises(Git::Error, /recovery identity changed/) do
          repo.merge.continue(author: OperationMetadataAdversarialSpec::SIGNATURE,
            committer: OperationMetadataAdversarialSpec::SIGNATURE)
        end
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        File.read(File.join(root, ".git", "index")).should eq(before_index)
        File.read(File.join(root, ".git", "CRYSTAL_MERGE_PATHS")).should eq(receipt)
        File.read(File.join(root, "tracked")).should eq("resolved\n")
        File.read(File.join(root, "caller")).should eq("preserve caller\n")
        File.write(File.join(root, ".git", "MERGE_HEAD"), "#{theirs}\n")
        oid = repo.merge.continue(author: OperationMetadataAdversarialSpec::SIGNATURE,
          committer: OperationMetadataAdversarialSpec::SIGNATURE)
        GitOracle.run(root, "show", "-s", "--format=%P", oid).stdout.strip.should eq("#{ours} #{theirs}")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("?? caller\n")
      end
    end
  end
end

describe "Git operation metadata rejects FIFOs without a writer" do
  {"MERGE_HEAD", "CRYSTAL_MERGE_ORIG", "CRYSTAL_MERGE_PATHS", "MERGE_MSG"}.each do |name|
    it "rejects merge #{name}" do
      GitOracle.with_repo { |root| OperationMetadataAdversarialSpec.reject_fifo(root, "merge", name) }
    end
  end

  {"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "CRYSTAL_SEQUENCER_ORIG",
   "CRYSTAL_SEQUENCER_PARENT", "CRYSTAL_SEQUENCER_AUTHOR", "CRYSTAL_SEQUENCER_ALLOW_EMPTY",
   "CRYSTAL_SEQUENCER_PATHS", "MERGE_MSG"}.each do |name|
    it "rejects sequencer #{name}" do
      GitOracle.with_repo { |root| OperationMetadataAdversarialSpec.reject_fifo(root, "sequencer", name) }
    end
  end

  {"head-name", "orig-head", "upstream", "onto", "git-rebase-todo", "state"}.each do |name|
    it "rejects rebase #{name}" do
      GitOracle.with_repo { |root| OperationMetadataAdversarialSpec.reject_fifo(root, "rebase", name) }
    end
  end
end
