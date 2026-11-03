require "spec"
require "../src/git"
require "./support/git_oracle"

# The child exits with _exit in the middle of publication, leaving Git's
# ordinary .lock files behind. No Crystal ensure/rescue is executed.
if root = ENV["CR_GIT_RECOVERY_CHILD"]?
  repo = Git::Repository.new(root)
  old_oid = ENV["CR_GIT_RECOVERY_OLD"]
  new_oid = ENV["CR_GIT_RECOVERY_NEW"]
  changes = [] of Git::References::Change
  changes << Git::References::Update.new("refs/heads/a", new_oid, old_oid)
  changes << Git::References::Update.new("refs/heads/b", new_oid, nil)
  changes << Git::References::Delete.new("refs/heads/obsolete", old_oid)
  repo.change_refs_recoverably(changes, id: "killed-writer",
    after_publish: ->(name : String) do
      LibC._exit(73) if name == "refs/heads/a"
      nil
    end)
  LibC._exit(72)
end

# Kill the writer after the branch log is durable, but before its HEAD log.
if root = ENV["CR_GIT_REFLOG_RECOVERY_CHILD"]?
  repo = Git::Repository.new(root)
  old_oid = ENV["CR_GIT_RECOVERY_OLD"]
  new_oid = ENV["CR_GIT_RECOVERY_NEW"]
  log = Git::References::LogEntry.new(Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0), "crash")
  changes = [] of Git::References::Change
  changes << Git::References::Update.new("refs/heads/main", new_oid, old_oid, log)
  repo.change_refs_recoverably(changes, id: "crash-reflog",
    after_reflog: ->(name : String) do
      LibC._exit(74) if name == "refs/heads/main"
      nil
    end)
  LibC._exit(72)
end

describe "P19 explicit durable mixed-ref redo journal" do
  ["sha1", "sha256"].each do |format|
    it "P19-O27 resumes #{format} mixed refs from a durable partial-publication journal" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_700_000_000_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
        repo.update_ref("refs/heads/alpha", first, expected_oid: nil)
        repo.update_ref("refs/heads/obsolete", first, expected_oid: nil)
        GitOracle.run(root, "pack-refs", "--all")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/alpha", second, first)
        changes << Git::References::Update.new("refs/heads/new", first, nil)
        changes << Git::References::Delete.new("refs/heads/obsolete", first)
        observer = ->(name : String) { raise Git::Error.new("interrupted after first ref") if name == "refs/heads/alpha" }
        error = expect_raises(Git::References::PartialPublication) do
          repo.change_refs_recoverably(changes, id: "resume-#{format}", after_publish: observer)
        end
        error.published_refs.should eq(["refs/heads/alpha"])
        repo.pending_ref_recoveries.should eq(["resume-#{format}"])
        repo.recover_refs("resume-#{format}")
        repo.pending_ref_recoveries.should be_empty
        GitOracle.run(root, "rev-parse", "refs/heads/alpha").stdout.strip.should eq(second)
        GitOracle.run(root, "rev-parse", "refs/heads/new").stdout.strip.should eq(first)
        GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete", check: false).success?.should be_false
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end
  end

  it "P19-O34 completes a real _exit-interrupted packed/mixed batch with explicit lock recovery" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old_oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      new_oid = repo.write_commit(tree: tree, parents: [old_oid], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/a", old_oid, expected_oid: nil)
      repo.update_ref("refs/heads/obsolete", old_oid, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      child = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_RECOVERY_CHILD" => root, "CR_GIT_RECOVERY_OLD" => old_oid,
              "CR_GIT_RECOVERY_NEW" => new_oid},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      child.exit_code.should eq(73)
      repo.pending_ref_recoveries.should eq(["killed-writer"])
      File.exists?(File.join(root, ".git", "refs", "heads", "b.lock")).should be_true
      expect_raises(Git::Error, /blocked by ref lock/) { repo.recover_refs("killed-writer") }
      repo.recover_refs("killed-writer", clear_abandoned_locks: true)
      repo.pending_ref_recoveries.should be_empty
      GitOracle.run(root, "rev-parse", "refs/heads/a").stdout.strip.should eq(new_oid)
      GitOracle.run(root, "rev-parse", "refs/heads/b").stdout.strip.should eq(new_oid)
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete", check: false).success?.should be_false
      GitOracle.run(root, "fsck", "--no-reflogs")
    end
  end

  it "P19-O33 removes an orphaned deleted-ref reflog during forward recovery" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      log = Git::References::LogEntry.new(sig, "created")
      repo.update_ref("refs/heads/obsolete", oid, expected_oid: nil, log: log)
      reflog = File.join(root, ".git", "logs", "refs", "heads", "obsolete")
      File.file?(reflog).should be_true
      changes = [] of Git::References::Change
      changes << Git::References::Delete.new("refs/heads/obsolete", oid)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "orphan-log", after_publish: ->(_name : String) { raise "interrupt before log cleanup" })
      end
      File.file?(reflog).should be_true
      repo.recover_refs("orphan-log")
      File.exists?(reflog).should be_false
      repo.pending_ref_recoveries.should be_empty
    end
  end

  it "P19-O28 recovers a completed transaction whose durable journal survived cleanup" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "done")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/new", oid, nil)
      # Synthesize a post-crash persisted valid journal by interrupting just
      # after the only ref was published, rather than editing private bytes.
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "already-done", after_publish: ->(_name : String) { raise "exit before journal cleanup" })
      end
      repo.recover_refs("already-done")
      repo.pending_ref_recoveries.should be_empty
      GitOracle.run(root, "rev-parse", "refs/heads/new").stdout.strip.should eq(oid)
    end
  end

  it "P19-O29 refuses divergent refs and retains the recovery journal without overwriting changes" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid1 = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      oid2 = repo.write_commit(tree: tree, parents: [oid1], author: sig, committer: sig, message: "two")
      oid3 = repo.write_commit(tree: tree, parents: [oid2], author: sig, committer: sig, message: "three")
      repo.update_ref("refs/heads/a", oid1, expected_oid: nil)
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/a", oid2, oid1)
      changes << Git::References::Update.new("refs/heads/z", oid2, nil)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "diverged", after_publish: ->(_name : String) { raise "stop" })
      end
      repo.update_ref("refs/heads/a", oid3, expected_oid: oid2)
      expect_raises(Git::References::Recovery::Conflict, /conflict/) { repo.recover_refs("diverged") }
      repo.pending_ref_recoveries.should eq(["diverged"])
      repo.resolve_ref?("refs/heads/a").should eq(oid3)
      repo.resolve_ref?("refs/heads/z").should be_nil
    end
  end

  it "P19-O30 supports valid reflogs but rejects stale CAS without leaving redo records" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      log = Git::References::LogEntry.new(sig, "not idempotent")
      with_log = [] of Git::References::Change
      with_log << Git::References::Update.new("refs/heads/new", oid, nil, log)
      repo.change_refs_recoverably(with_log, id: "allowed")
      File.read(File.join(root, ".git", "logs", "refs", "heads", "new")).should eq(log.encode("0" * repo.object_format.hexsize, oid))
      stale = [] of Git::References::Change
      stale << Git::References::Update.new("refs/heads/new", oid, nil)
      expect_raises(Git::Error, /compare-and-swap/) { repo.change_refs_recoverably(stale, id: "stale") }
      repo.pending_ref_recoveries.should be_empty
    end
  end

  it "P19-O31 fails closed on corrupted redo content and unsafe identifiers" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/new", oid, nil)
      expect_raises(Git::Error, /identifier/) { repo.change_refs_recoverably(changes, id: "../escape") }
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "corrupt", after_publish: ->(_name : String) { raise "stop" })
      end
      journal = File.join(root, ".git", "crystal-git-recovery", "corrupt.redo")
      File.open(journal, "a") { |io| io << "extra" }
      expect_raises(Git::Error, /checksum|envelope/) { repo.recover_refs("corrupt") }
      repo.pending_ref_recoveries.should eq(["corrupt"])
    end
  end

  it "P19-O32 requires an explicit maintenance grant before clearing an abandoned ref lock" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/a", oid, nil)
      changes << Git::References::Update.new("refs/heads/z", oid, nil)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "abandoned", after_publish: ->(_name : String) { raise "interrupt" })
      end
      lock = File.join(root, ".git", "refs", "heads", "z.lock")
      File.write(lock, "#{oid}\n")
      expect_raises(Git::Error, /blocked by ref lock/) { repo.recover_refs("abandoned") }
      File.exists?(lock).should be_true
      repo.recover_refs("abandoned", clear_abandoned_locks: true)
      File.exists?(lock).should be_false
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/z").should eq(oid)
    end
  end
end

describe "P19 idempotent reflog redo" do
  ["sha1", "sha256"].each do |format|
    it "P19-O35 writes byte-identical branch and HEAD logs for #{format}" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_700_000_000_i64, -300)
        tree = repo.write_tree([] of Git::Tree::Entry)
        first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
        initial = Git::References::LogEntry.new(sig, "initialize")
        repo.update_ref("refs/heads/main", first, expected_oid: nil, log: initial)
        before = File.read(File.join(root, ".git", "logs", "refs", "heads", "main"))
        next_log = Git::References::LogEntry.new(sig, "recoverable ref update")
        change = [] of Git::References::Change
        change << Git::References::Update.new("refs/heads/main", second, first, next_log)
        repo.change_refs_recoverably(change, id: "with-logs")
        branch = File.read(File.join(root, ".git", "logs", "refs", "heads", "main"))
        head_log = File.read(File.join(root, ".git", "logs", "HEAD"))
        branch.should eq(before + next_log.encode(first, second))
        head_log.should eq(initial.encode("0" * repo.object_format.hexsize, first) + next_log.encode(first, second))
        repo.pending_ref_recoveries.should be_empty
        GitOracle.run(root, "reflog", "show", "--format=%H", "refs/heads/main").stdout.lines.first.strip.should eq(second)
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end
  end

  it "P19-O36 replays an already appended branch log once and completes the HEAD log" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/main", first, expected_oid: nil)
      log = Git::References::LogEntry.new(sig, "recover-once")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", second, first, log)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "half-logs",
          after_reflog: ->(name : String) { raise "stop at branch log" if name == "refs/heads/main" })
      end
      branch_path = File.join(root, ".git", "logs", "refs", "heads", "main")
      expected = log.encode(first, second)
      File.read(branch_path).should eq(expected)
      head_path = File.join(root, ".git", "logs", "HEAD")
      File.exists?(head_path).should be_false
      repo.recover_refs("half-logs")
      File.read(branch_path).should eq(expected)
      File.read(head_path).should eq(expected)
      repo.pending_ref_recoveries.should be_empty
    end
  end

  it "P19-O37 completes a truncated reflog line without duplicating its prefix" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      log = Git::References::LogEntry.new(sig, "partial-recovery")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/topic", oid, nil, log)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "partial-log", after_publish: ->(_name : String) { raise "before log" })
      end
      path = File.join(root, ".git", "logs", "refs", "heads", "topic")
      Dir.mkdir_p(File.dirname(path))
      line = log.encode("0" * repo.object_format.hexsize, oid)
      File.write(path, line.byte_slice(0, 19))
      repo.recover_refs("partial-log")
      File.read(path).should eq(line)
      repo.pending_ref_recoveries.should be_empty
    end
  end

  it "P19-O38 refuses a divergent reflog baseline without mutating other logs" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
      initial = Git::References::LogEntry.new(sig, "prior")
      repo.update_ref("refs/heads/main", first, expected_oid: nil, log: initial)
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", second, first, Git::References::LogEntry.new(sig, "new"))
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "log-conflict", after_publish: ->(_name : String) { raise "no log" })
      end
      branch_path = File.join(root, ".git", "logs", "refs", "heads", "main")
      File.open(branch_path, "a") { |io| io << "alien record\n" }
      before_head = File.read(File.join(root, ".git", "logs", "HEAD"))
      expect_raises(Git::References::Recovery::Conflict, /diverged/) { repo.recover_refs("log-conflict") }
      File.read(File.join(root, ".git", "logs", "HEAD")).should eq(before_head)
      repo.pending_ref_recoveries.should eq(["log-conflict"])
    end
  end

  it "P19-O39 resumes after real child-process death during reflog publication" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/main", first, expected_oid: nil)
      child = Process.run(Process.executable_path.not_nil!, [] of String,
        env: {"CR_GIT_REFLOG_RECOVERY_CHILD" => root, "CR_GIT_RECOVERY_OLD" => first, "CR_GIT_RECOVERY_NEW" => second},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      child.exit_code.should eq(74)
      repo.pending_ref_recoveries.should eq(["crash-reflog"])
      repo.recover_refs("crash-reflog")
      expected = Git::References::LogEntry.new(sig, "crash").encode(first, second)
      File.read(File.join(root, ".git", "logs", "refs", "heads", "main")).should eq(expected)
      File.read(File.join(root, ".git", "logs", "HEAD")).should eq(expected)
      GitOracle.run(root, "fsck", "--no-reflogs")
    end
  end
end

describe "P19 reflog recovery compatibility and refusal" do
  it "P19-O40 accepts a pre-v2 reflog-free journal with the original checksum" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/new", oid, nil)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "old-format", after_publish: ->(_name : String) { raise "stop" })
      end
      path = File.join(root, ".git", "crystal-git-recovery", "old-format.redo")
      raw = File.read(path)
      body = raw.split('\n', 2)[1]
      body.starts_with?("crystal-git-ref-redo-2\n").should be_true
      body.ends_with?("\n0\n").should be_true
      legacy = body.sub("crystal-git-ref-redo-2\n", "crystal-git-ref-redo-1\n")
      legacy = legacy.byte_slice(0, legacy.bytesize - 2)
      File.write(path, "#{Digest::SHA256.hexdigest(legacy)}\n#{legacy}")
      repo.recover_refs("old-format")
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/new").should eq(oid)
    end
  end

  it "P19-O41 detects a changed HEAD attachment and defers reflog replay" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/main", first, expected_oid: nil)
      log = Git::References::LogEntry.new(sig, "branch write")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", second, first, log)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "head-moved", after_publish: ->(_name : String) { raise "stop" })
      end
      GitOracle.run(root, "symbolic-ref", "HEAD", "refs/heads/other")
      expect_raises(Git::References::Recovery::Conflict, /HEAD moved/) { repo.recover_refs("head-moved") }
      repo.pending_ref_recoveries.should eq(["head-moved"])
      # Git's own symbolic-ref operation also changes the HEAD reflog. A
      # return to the old branch does NOT authorize overwriting that history.
      GitOracle.run(root, "symbolic-ref", "HEAD", "refs/heads/main")
      expect_raises(Git::References::Recovery::Conflict, /diverged/) { repo.recover_refs("head-moved") }
      repo.pending_ref_recoveries.should eq(["head-moved"])
    end
  end
end

describe "P19 reflog recovery safety" do
  it "P19-O42 refuses a symlinked reflog without creating refs or redo records" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      foreign = File.join(File.dirname(root), "unrelated")
      File.write(foreign, "protected")
      log_path = File.join(root, ".git", "logs", "refs", "heads", "topic")
      Dir.mkdir_p(File.dirname(log_path))
      File.symlink(foreign, log_path)
      log = Git::References::LogEntry.new(sig, "no redirect")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/topic", oid, nil, log)
      expect_raises(Git::Error, /reflog redirected/) { repo.change_refs_recoverably(changes, id: "symlink") }
      repo.resolve_ref?("refs/heads/topic").should be_nil
      repo.pending_ref_recoveries.should be_empty
      File.read(foreign).should eq("protected")
    end
  end

  it "P19-O43 completes an append interrupted after a nonempty reflog baseline" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "two")
      original_log = Git::References::LogEntry.new(sig, "first")
      repo.update_ref("refs/heads/topic", first, expected_oid: nil, log: original_log)
      log_path = File.join(root, ".git", "logs", "refs", "heads", "topic")
      before = File.read(log_path)
      next_log = Git::References::LogEntry.new(sig, "second")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/topic", second, first, next_log)
      expect_raises(Git::References::PartialPublication) do
        repo.change_refs_recoverably(changes, id: "nonempty", after_publish: ->(_name : String) { raise "stop" })
      end
      line = next_log.encode(first, second)
      File.open(log_path, "a") { |io| io << line.byte_slice(0, 27) }
      repo.recover_refs("nonempty")
      File.read(log_path).should eq(before + line)
      repo.pending_ref_recoveries.should be_empty
    end
  end
end
