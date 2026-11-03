require "spec"
require "../src/git"
require "./support/git_oracle"
require "c/sys/file"

# A hard process exit after Git-native barrier acquisition leaves both the
# durable journal and our finalization .lock files intact. No ensures execute.
if root = ENV["CR_GIT_FINALIZATION_CRASH"]?
  repo = Git::Repository.new(root)
  meta = Git::Metadata.new(root)
  changes = [] of Git::References::Change
  changes << Git::References::Update.new("refs/heads/main", ENV["CR_GIT_FINALIZATION_NEW"], ENV["CR_GIT_FINALIZATION_OLD"])
  Git::References::Recovery.run(meta, repo.object_format, "killed-finalizer", changes,
    finalization_probe: -> { LibC._exit(79) }) do |pending|
    repo.change_refs(pending)
  end
  LibC._exit(78)
end

describe "P18/P19 recovery coexistence with external Git writers" do
  it "P19-O45 refuses another durable writer while the persistent repository guard is held" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Guard", "guard@example.invalid", 10_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: actor, committer: actor, message: "guard")
      first = [] of Git::References::Change
      first << Git::References::Update.new("refs/heads/first", oid, nil)
      repo.change_refs_recoverably(first, id: "guard-first")
      guard = File.join(root, ".git", "crystal-git-recovery", "active.lock")
      File.file?(guard).should be_true
      fd = LibC.open(guard, LibC::O_RDWR | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
      fd.should be >= 0
      begin
        (LibC.flock(fd, LibC::FlockOp::EX | LibC::FlockOp::NB) == 0).should be_true
        next_changes = [] of Git::References::Change
        next_changes << Git::References::Update.new("refs/heads/second", oid, nil)
        expect_raises(Git::Error, /repository is busy/) { repo.change_refs_recoverably(next_changes, id: "guard-second") }
        repo.resolve_ref?("refs/heads/second").should be_nil
        repo.pending_ref_recoveries.should be_empty
      ensure
        LibC.close(fd)
      end
    end
  end

  it "P19-O46 blocks new transactions until an interrupted journal is recovered" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Guard", "guard@example.invalid", 10_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: actor, committer: actor, message: "guard")
      first = [] of Git::References::Change
      first << Git::References::Update.new("refs/heads/first", oid, nil)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(first, id: "unfinished", after_publish: ->(_name : String) { raise "interrupt" })
      end
      next_changes = [] of Git::References::Change
      next_changes << Git::References::Update.new("refs/heads/second", oid, nil)
      expect_raises(Git::Error, /pending journal/) { repo.change_refs_recoverably(next_changes, id: "second") }
      repo.pending_ref_recoveries.should eq(["unfinished"])
      repo.recover_refs("unfinished")
      repo.change_refs_recoverably(next_changes, id: "second")
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/second").should eq(oid)
    end
  end

  ["sha1", "sha256"].each do |format|
    it "P19-O47 keeps #{format} redo intent when external Git advances the ref during reflog completion" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("External", "external@example.invalid", 50_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
        external = repo.write_commit(tree: tree, parents: [desired], author: actor, committer: actor, message: "external")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        log = Git::References::LogEntry.new(actor, "native")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old, log)
        updated = false
        expect_raises(Git::References::PartialPublication) do
          repo.change_refs_recoverably(changes, id: "foreign-#{format}", after_reflog: ->(_path : String) do
            unless updated
              updated = true
              GitOracle.run(root, "update-ref", "refs/heads/main", external, desired)
            end
            nil
          end)
        end
        updated.should be_true
        repo.pending_ref_recoveries.should eq(["foreign-#{format}"])
        repo.resolve_ref?("refs/heads/main").should eq(external)
        expect_raises(Git::References::Recovery::Conflict) { repo.recover_refs("foreign-#{format}") }
        repo.resolve_ref?("refs/heads/main").should eq(external)
      end
    end

    it "P18-O19 keeps #{format} journal if external git add replaces the index after native publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("External", "external@example.invalid", 50_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        staged = repo.write_blob("native\n")
        edits = [] of Git::Index::Edit
        edits << Git::Index::Put.new("native.txt", "100644", staged)
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        File.write(File.join(root, "external.txt"), "external\n")
        expect_raises(Git::References::PartialPublication) do
          repo.change_index_and_refs_recoverably(edits, changes, id: "foreign-index-#{format}",
            after_index_publish: -> { GitOracle.run(root, "add", "external.txt"); nil })
        end
        repo.pending_ref_recoveries.should eq(["foreign-index-#{format}"])
        GitOracle.run(root, "ls-files", "--stage", "external.txt").stdout.should contain("external.txt")
        expect_raises(Git::Error) { repo.recover_index_and_refs("foreign-index-#{format}") }
        repo.pending_ref_recoveries.should eq(["foreign-index-#{format}"])
      end
    end
  end

  ["sha1", "sha256"].each do |format|
    it "P19-O48 retains #{format} journal when foreign ref lock blocks finalization" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Barrier", "barrier@example.invalid", 50_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        first = repo.write_commit(tree: tree, author: actor, committer: actor, message: "first")
        second = repo.write_commit(tree: tree, parents: [first], author: actor, committer: actor, message: "second")
        repo.update_ref("refs/heads/main", first, expected_oid: nil)
        log = Git::References::LogEntry.new(actor, "native barrier")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", second, first, log)
        foreign = File.join(root, ".git", "refs", "heads", "main.lock")
        injected = false
        error = expect_raises(Git::References::PartialPublication) do
          repo.change_refs_recoverably(changes, id: "foreign-lock-#{format}",
            after_reflog: ->(_name : String) do
              unless injected
                File.write(foreign, "foreign writer")
                injected = true
              end
              nil
            end)
        end
        injected.should be_true
        error.original_error.message.not_nil!.should contain("finalization blocked by Git lock")
        File.read(foreign).should eq("foreign writer")
        repo.pending_ref_recoveries.should eq(["foreign-lock-#{format}"])
        File.delete(foreign) # Simulated foreign writer has now exited.
        repo.recover_refs("foreign-lock-#{format}")
        repo.resolve_ref?("refs/heads/main").should eq(second)
        repo.pending_ref_recoveries.should be_empty
        File.exists?(foreign).should be_false
        File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
        GitOracle.run(root, "update-ref", "refs/heads/main", first, second)
      end
    end

    it "P18-O20 retains #{format} joint intent when foreign index lock blocks finalization" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Barrier", "barrier@example.invalid", 50_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        first = repo.write_commit(tree: tree, author: actor, committer: actor, message: "first")
        second = repo.write_commit(tree: tree, parents: [first], author: actor, committer: actor, message: "second")
        repo.update_ref("refs/heads/main", first, expected_oid: nil)
        blob = repo.write_blob("staged barrier\n")
        edits = [] of Git::Index::Edit
        edits << Git::Index::Put.new("staged.txt", "100644", blob)
        log = Git::References::LogEntry.new(actor, "native barrier")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", second, first, log)
        foreign = File.join(root, ".git", "index.lock")
        injected = false
        error = expect_raises(Git::References::PartialPublication) do
          repo.change_index_and_refs_recoverably(edits, changes, id: "foreign-index-lock-#{format}",
            after_reflog: ->(_name : String) do
              unless injected
                File.write(foreign, "foreign index writer")
                injected = true
              end
              nil
            end)
        end
        injected.should be_true
        error.original_error.message.not_nil!.should contain("finalization blocked by Git lock")
        File.read(foreign).should eq("foreign index writer")
        repo.pending_ref_recoveries.should eq(["foreign-index-lock-#{format}"])
        File.delete(foreign)
        repo.recover_index_and_refs("foreign-index-lock-#{format}")
        repo.pending_ref_recoveries.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(second)
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("staged.txt")
        File.exists?(foreign).should be_false
        GitOracle.run(root, "add", "--all")
      end
    end
  end

  it "P19-O49 retains mixed batch when foreign packed-refs lock blocks finalization" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Barrier", "barrier@example.invalid", 50_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: actor, committer: actor, message: "first")
      second = repo.write_commit(tree: tree, parents: [first], author: actor, committer: actor, message: "second")
      repo.update_ref("refs/heads/main", first, expected_oid: nil)
      log = Git::References::LogEntry.new(actor, "barrier")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", second, first, log)
      foreign = File.join(root, ".git", "packed-refs.lock")
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "foreign-packed-lock",
          after_reflog: ->(_name : String) { File.write(foreign, "packed writer"); nil })
      end
      File.read(foreign).should eq("packed writer")
      repo.pending_ref_recoveries.should eq(["foreign-packed-lock"])
      File.delete(foreign)
      repo.recover_refs("foreign-packed-lock")
      repo.pending_ref_recoveries.should be_empty
      File.exists?(foreign).should be_false
      GitOracle.run(root, "pack-refs", "--all")
    end
  end

  ["sha1", "sha256"].each do |format|
    it "P19-O50 blocks real #{format} Git ref, pack-refs and add writers while finalizing a joint redo" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Barrier", "barrier@example.invalid", 50_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
        later = repo.write_commit(tree: tree, parents: [desired], author: actor, committer: actor, message: "later")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        File.write(File.join(root, "external.txt"), "outside\n")
        blob = repo.write_blob("index\n")
        edits = [] of Git::Index::Edit
        edits << Git::Index::Put.new("native.txt", "100644", blob)
        metadata = Git::Metadata.new(root)
        database = Git::ObjectDatabase.new(metadata.common, repo.object_format)
        head_tree = Git::HeadTree.new(metadata, database, 10_000, repo.object_format)
        index_store = Git::Index.new(metadata, head_tree, database, repo.object_format, 10_000)
        image = index_store.prepare_changes_plan(edits).image
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        inspected = false
        Git::References::Recovery.run(metadata, repo.object_format, "held-#{format}", changes,
          index_image: image, index_store: index_store,
          finalization_probe: -> do
            inspected = true
            File.exists?(File.join(root, ".git", "index.lock")).should be_true
            File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_true
            File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_true
            GitOracle.run(root, "update-ref", "refs/heads/main", later, desired, check: false).success?.should be_false
            GitOracle.run(root, "add", "external.txt", check: false).success?.should be_false
            GitOracle.run(root, "pack-refs", "--all", check: false).success?.should be_false
            nil
          end) do |batch|
          repo.change_refs(batch)
        end
        inspected.should be_true
        repo.pending_ref_recoveries.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(desired)
        ["index.lock", "packed-refs.lock", "refs/heads/main.lock"].each do |suffix|
          File.exists?(File.join(root, ".git", suffix)).should be_false
        end
        GitOracle.run(root, "add", "external.txt")
        GitOracle.run(root, "update-ref", "refs/heads/main", later, desired)
        GitOracle.run(root, "pack-refs", "--all")
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("external.txt")
      end
    end
  end
  it "P19-O51 resumes a real _exit-killed finalizer with explicit maintenance lock cleanup" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Barrier", "barrier@example.invalid", 50_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
      desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "desired")
      repo.update_ref("refs/heads/main", old, expected_oid: nil)
      child = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_FINALIZATION_CRASH" => root,
              "CR_GIT_FINALIZATION_OLD" => old, "CR_GIT_FINALIZATION_NEW" => desired},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      child.exit_code.should eq(79)
      repo.pending_ref_recoveries.should eq(["killed-finalizer"])
      ["packed-refs.lock", "refs/heads/main.lock"].each do |suffix|
        File.exists?(File.join(root, ".git", suffix)).should be_true
      end
      expect_raises(Git::Error, /blocked by ref lock/) { repo.recover_refs("killed-finalizer") }
      # Only a trusted maintenance caller that has certified process
      # quiescence can remove dead Git lock files.
      repo.recover_refs("killed-finalizer", clear_abandoned_locks: true)
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/main").should eq(desired)
      ["packed-refs.lock", "refs/heads/main.lock"].each do |suffix|
        File.exists?(File.join(root, ".git", suffix)).should be_false
      end
      GitOracle.run(root, "update-ref", "refs/heads/main", old, desired)
    end
  end
end
