require "spec"
require "../src/git"
require "./support/git_oracle"
require "c/sys/file"

# A real _exit skips all ensures. The child must publish refs, take the Git
# finalization locks and persist the ownership receipt before exiting.
if root = ENV["CR_GIT_FINAL_RECEIPT_CHILD"]?
  repo = Git::Repository.new(root)
  meta = Git::Metadata.new(root)
  name = ENV["CR_GIT_FINAL_RECEIPT_ID"]
  old = ENV["CR_GIT_FINAL_RECEIPT_OLD"]
  desired = ENV["CR_GIT_FINAL_RECEIPT_NEW"]
  stage = ENV["CR_GIT_FINAL_RECEIPT_STAGE"]
  with_index = ENV["CR_GIT_FINAL_RECEIPT_INDEX"] == "1"
  image = nil.as(Git::Index::Image?)
  index_store = nil.as(Git::Index?)
  if with_index
    db = Git::ObjectDatabase.new(meta.common, repo.object_format)
    head_tree = Git::HeadTree.new(meta, db, 10_000, repo.object_format)
    index_store = Git::Index.new(meta, head_tree, db, repo.object_format, 10_000)
    blob = repo.write_blob("journaled index\n")
    edits = [] of Git::Index::Edit
    edits << Git::Index::Put.new("pending.txt", "100644", blob)
    image = index_store.prepare_changes(edits)
  end
  changes = [] of Git::References::Change
  changes << Git::References::Update.new("refs/heads/main", desired, old)
  Git::References::Recovery.run(meta, repo.object_format, name, changes,
    index_image: image, index_store: index_store,
    after_receipt_durable: (stage == "before" ? -> { LibC._exit(87); nil } : nil),
    after_journal_unlink: (stage == "after" ? -> { LibC._exit(88); nil } : nil)) do |pending|
    repo.refs.apply(pending)
  end
  LibC._exit(86)
end

describe "P19 crash-safe finalization receipt" do
  ["sha1", "sha256"].each do |format|
    ["before", "after"].each do |stage|
      it "P19-O52 recovers #{format} finalizer killed #{stage} redo deletion" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
          tree = repo.write_tree([] of Git::Tree::Entry)
          old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
          desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
          later = repo.write_commit(tree: tree, parents: [desired], author: actor, committer: actor, message: "later")
          repo.refs.update("refs/heads/main", old, expected_oid: nil)
          ident = "finish-#{stage}-#{format}"
          result = Process.run(Process.executable_path.not_nil!, [] of String,
            env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root,
                  "CR_GIT_FINAL_RECEIPT_STAGE" => stage,
                  "CR_GIT_FINAL_RECEIPT_INDEX" => "0",
                  "CR_GIT_FINAL_RECEIPT_ID"    => ident,
                  "CR_GIT_FINAL_RECEIPT_OLD"   => old,
                  "CR_GIT_FINAL_RECEIPT_NEW"   => desired},
            output: Process::Redirect::Close, error: Process::Redirect::Close)
          result.exit_code.should eq(stage == "before" ? 87 : 88)
          dir = File.join(root, ".git", "crystal-git-recovery")
          File.file?(File.join(dir, "#{ident}.finish")).should be_true
          File.file?(File.join(dir, "#{ident}.redo")).should eq(stage == "before")
          repo.recovery.pending_finalizations.should eq([ident])
          repo.recovery.pending.should eq(stage == "before" ? [ident] : [] of String)
          File.file?(File.join(root, ".git", "packed-refs.lock")).should be_true
          File.file?(File.join(root, ".git", "refs/heads/main.lock")).should be_true
          GitOracle.run(root, "update-ref", "refs/heads/main", later, desired, check: false).success?.should be_false
          changes = [] of Git::References::Change
          changes << Git::References::Update.new("refs/heads/another", desired, nil)
          expect_raises(Git::Error, /pending/) { repo.recovery.apply(changes, id: "blocked") }
          repo.recovery.finish_finalization(ident)
          repo.recovery.pending_finalizations.should be_empty
          repo.recovery.pending.should be_empty
          File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
          File.exists?(File.join(root, ".git", "refs/heads/main.lock")).should be_false
          repo.refs.resolve?("refs/heads/main").should eq(desired)
          GitOracle.run(root, "update-ref", "refs/heads/main", later, desired)
        end
      end
    end

    it "P19-O53 finishes #{format} journal-free receipt after partial lock cleanup" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
        repo.refs.update("refs/heads/main", old, expected_oid: nil)
        ident = "partial-#{format}"
        result = Process.run(Process.executable_path.not_nil!, [] of String,
          env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
                "CR_GIT_FINAL_RECEIPT_INDEX" => "1", "CR_GIT_FINAL_RECEIPT_ID" => ident,
                "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        result.exit_code.should eq(88)
        File.exists?(File.join(root, ".git", "index.lock")).should be_true
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("pending.txt")
        File.delete(File.join(root, ".git", "index.lock")) # Completed half of a dead finalizer's cleanup
        repo.recovery.finish_finalization(ident)
        repo.recovery.pending_finalizations.should be_empty
        File.exists?(File.join(root, ".git", "refs/heads/main.lock")).should be_false
        File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("pending.txt")
        GitOracle.run(root, "add", "--all")
      end
    end
  end

  it "P19-O54 preserves foreign replacement locks rather than deleting them" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.refs.update("refs/heads/main", old, expected_oid: nil)
      ident = "foreign-after"
      status = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
              "CR_GIT_FINAL_RECEIPT_INDEX" => "0", "CR_GIT_FINAL_RECEIPT_ID" => ident,
              "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.exit_code.should eq(88)
      foreign = File.join(root, ".git", "refs", "heads", "main.lock")
      original = File.read(foreign)
      File.delete(foreign)
      File.write(foreign, "foreign writer lock\n")
      expect_raises(Git::References::Recovery::Conflict, /foreign lock/) { repo.recovery.finish_finalization(ident) }
      File.read(foreign).should eq("foreign writer lock\n")
      repo.recovery.pending_finalizations.should eq([ident])
      File.write(foreign, original)
      repo.recovery.finish_finalization(ident)
      repo.recovery.pending_finalizations.should be_empty
    end
  end

  it "P19-O55 preserves finalization receipt on ref divergence" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.refs.update("refs/heads/main", old, expected_oid: nil)
      ident = "ref-divergence"
      status = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
              "CR_GIT_FINAL_RECEIPT_INDEX" => "0", "CR_GIT_FINAL_RECEIPT_ID" => ident,
              "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.exit_code.should eq(88)
      ref = File.join(root, ".git", "refs", "heads", "main")
      File.write(ref, "#{old}\n") # Explicitly simulate a writer bypassing Git's lock protocol
      expect_raises(Git::References::Recovery::Conflict, /ref diverged/) { repo.recovery.finish_finalization(ident) }
      repo.recovery.pending_finalizations.should eq([ident])
      File.write(ref, "#{desired}\n")
      repo.recovery.finish_finalization(ident)
      repo.recovery.pending_finalizations.should be_empty
    end
  end

  it "P19-O56 refuses modified receipts without releasing recorded locks" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.refs.update("refs/heads/main", old, expected_oid: nil)
      status = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
              "CR_GIT_FINAL_RECEIPT_INDEX" => "0", "CR_GIT_FINAL_RECEIPT_ID" => "corrupt",
              "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.exit_code.should eq(88)
      path = File.join(root, ".git", "crystal-git-recovery", "corrupt.finish")
      original = File.read(path)
      File.write(path, original.sub("crystal-git-finalization-1", "crystal-git-finalization-0"))
      expect_raises(Git::Error, /checksum mismatch/) { repo.recovery.finish_finalization("corrupt") }
      File.file?(File.join(root, ".git", "refs/heads/main.lock")).should be_true
      File.write(path, original)
      repo.recovery.finish_finalization("corrupt")
      repo.recovery.pending_finalizations.should be_empty
    end
  end

  it "P19-O57 refuses symlinked orphan locks without changing their targets" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.refs.update("refs/heads/main", old, expected_oid: nil)
      status = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
              "CR_GIT_FINAL_RECEIPT_INDEX" => "0", "CR_GIT_FINAL_RECEIPT_ID" => "symlink",
              "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.exit_code.should eq(88)
      lock = File.join(root, ".git", "packed-refs.lock")
      token = File.read(lock)
      target = File.join(root, "protected.txt")
      File.write(target, "preserve this\n")
      File.delete(lock)
      File.symlink(target, lock)
      expect_raises(Git::References::Recovery::Conflict, /foreign or redirected lock/) { repo.recovery.finish_finalization("symlink") }
      File.read(target).should eq("preserve this\n")
      repo.recovery.pending_finalizations.should eq(["symlink"])
      File.delete(lock)
      File.write(lock, token)
      repo.recovery.finish_finalization("symlink")
      repo.recovery.pending_finalizations.should be_empty
    end
  end

  it "P18-O21 refuses a changed index and retains the orphan receipt" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.refs.update("refs/heads/main", old, expected_oid: nil)
      status = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINAL_RECEIPT_CHILD" => root, "CR_GIT_FINAL_RECEIPT_STAGE" => "after",
              "CR_GIT_FINAL_RECEIPT_INDEX" => "1", "CR_GIT_FINAL_RECEIPT_ID" => "index-divergence",
              "CR_GIT_FINAL_RECEIPT_OLD" => old, "CR_GIT_FINAL_RECEIPT_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.exit_code.should eq(88)
      index_file = File.join(root, ".git", "index")
      original = File.read(index_file)
      File.write(index_file, "not a Git index") # Noncooperative writer, bypassing index.lock
      expect_raises(Git::References::Recovery::Conflict, /index diverged/) { repo.recovery.finish_finalization("index-divergence") }
      repo.recovery.pending_finalizations.should eq(["index-divergence"])
      File.write(index_file, original)
      repo.recovery.finish_finalization("index-divergence")
      repo.recovery.pending_finalizations.should be_empty
    end
  end

  it "P19-O58 removes finalization receipts and owned locks on normal success" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Receipt", "receipt@example.invalid", 100_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/new", oid, nil)
      repo.recovery.apply(changes, id: "normal-success")
      repo.recovery.pending.should be_empty
      repo.recovery.pending_finalizations.should be_empty
      File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
      File.exists?(File.join(root, ".git", "refs/heads/new.lock")).should be_false
      expect_raises(Git::Error, /missing/) { repo.recovery.finish_finalization("normal-success") }
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/new")
    end
  end
end
