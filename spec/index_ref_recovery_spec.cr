require "spec"
require "../src/git"
require "./support/git_oracle"

module GitIndexRefOracle
  def self.fixture(root : String)
    repo = Git::Repository.new(root)
    actor = Git::Signature.new("Index Recovery", "index-recovery@example.invalid", 1_700_000_000_i64, -300)
    blob = repo.write_blob("index-ref payload\n")
    empty = repo.write_tree([] of Git::Tree::Entry)
    old_oid = repo.write_commit(tree: empty, author: actor, committer: actor, message: "old")
    tree = repo.write_tree([Git::Tree::Entry.new("joint.txt", "100644", blob)])
    new_oid = repo.write_commit(tree: tree, parents: [old_oid], author: actor, committer: actor, message: "new")
    repo.update_ref("refs/heads/main", old_oid, expected_oid: nil)
    {repo: repo, actor: actor, blob: blob, old_oid: old_oid, new_oid: new_oid, tree: tree}
  end

  def self.edits(blob : String) : Array(Git::Index::Edit)
    edits = [] of Git::Index::Edit
    edits << Git::Index::Put.new("joint.txt", "100644", blob)
    edits
  end

  def self.refs(old_oid : String, new_oid : String, actor : Git::Signature, *, with_log : Bool = false) : Array(Git::References::Change)
    log = with_log ? Git::References::LogEntry.new(actor, "joint recovery") : nil
    refs = [] of Git::References::Change
    refs << Git::References::Update.new("refs/heads/main", new_oid, old_oid, log)
    refs
  end
end

# Test a process killed before index.lock can be renamed and after it is
# renamed, so no Crystal ensure cleanup occurs in either path.
if root = ENV["CR_GIT_INDEX_REF_CRASH"]?
  repo = Git::Repository.new(root)
  blob = ENV["CR_GIT_INDEX_REF_BLOB"]
  old = ENV["CR_GIT_INDEX_REF_OLD"]
  fresh = ENV["CR_GIT_INDEX_REF_NEW"]
  edits = GitIndexRefOracle.edits(blob)
  refs = GitIndexRefOracle.refs(old, fresh,
    Git::Signature.new("Index Recovery", "index-recovery@example.invalid", 1_i64, 0))
  if ENV["CR_GIT_INDEX_REF_PHASE"] == "locked"
    check = -> do
      LibC._exit(77) if File.exists?(File.join(root, ".git", "index.lock"))
      nil
    end
    repo.change_index_and_refs_recoverably(edits, refs, id: "crashed-locked", check: check)
  else
    repo.change_index_and_refs_recoverably(edits, refs, id: "crashed-published",
      after_index_publish: -> { LibC._exit(78) })
  end
  LibC._exit(76)
end

describe "P18/P19 coordinated index and references forward recovery" do
  ["sha1", "sha256"].each do |format|
    it "P18/19-O01 resumes #{format} index, commit ref and exact reflogs after publication interruption" do
      GitOracle.with_repo(format: format) do |root|
        fixture = GitIndexRefOracle.fixture(root)
        repo = fixture[:repo]
        edits = GitIndexRefOracle.edits(fixture[:blob])
        refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor], with_log: true)
        expect_raises(Git::References::PartialPublication) do
          repo.change_index_and_refs_recoverably(edits, refs, id: "index-main-#{format}",
            after_index_publish: -> { raise Git::Error.new("stop after index rename") })
        end
        repo.resolve_ref?("refs/heads/main").should eq(fixture[:old_oid])
        repo.write_index_tree.should eq(fixture[:tree])
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("#{fixture[:blob]} 0\tjoint.txt")
        repo.pending_ref_recoveries.should eq(["index-main-#{format}"])
        expect_raises(Git::Error, /index publisher required/) { repo.recover_refs("index-main-#{format}") }
        repo.recover_index_and_refs("index-main-#{format}")
        repo.pending_ref_recoveries.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(fixture[:new_oid])
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(fixture[:new_oid])
        line = Git::References::LogEntry.new(fixture[:actor], "joint recovery").encode(fixture[:old_oid], fixture[:new_oid])
        [File.join(root, ".git", "logs", "HEAD"), File.join(root, ".git", "logs", "refs", "heads", "main")].each do |path|
          File.read(path).should eq(line)
        end
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end

    it "P18/19-O02 publishes one #{format} durable v3 journal for index and multi-ref partial completion" do
      GitOracle.with_repo(format: format) do |root|
        fixture = GitIndexRefOracle.fixture(root)
        repo = fixture[:repo]
        refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
        refs << Git::References::Update.new("refs/heads/z", fixture[:new_oid], nil)
        expect_raises(Git::References::PartialPublication) do
          repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "mixed-#{format}",
            after_publish: ->(_name : String) { raise "stop after first ref" })
        end
        repo.pending_ref_recoveries.should eq(["mixed-#{format}"])
        repo.recover_index_and_refs("mixed-#{format}")
        repo.resolve_ref?("refs/heads/z").should eq(fixture[:new_oid])
        repo.write_index_tree.should eq(fixture[:tree])
        repo.pending_ref_recoveries.should be_empty
      end
    end
  end

  [2, 3, 4].each do |version|
    it "P18/19-O03 preserves Git index v#{version} and its existing flags through joint recovery" do
      GitOracle.with_repo do |root|
        fixture = GitIndexRefOracle.fixture(root)
        repo = fixture[:repo]
        repo.stage_blob("existing.txt", "unchanged\n")
        GitOracle.run(root, "update-index", "--assume-unchanged", "existing.txt")
        GitOracle.run(root, "update-index", "--index-version", version.to_s)
        GitOracle.run(root, "update-index", "--skip-worktree", "existing.txt") if version > 2
        refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
        repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "v#{version}")
        GitOracle.run(root, "ls-files", "-v").stdout.should contain(version > 2 ? "s existing.txt" : "h existing.txt")
        File.read(File.join(root, ".git", "index")).byte_at(7).should eq(version)
        GitOracle.run(root, "ls-files", "--stage").stdout.should contain("joint.txt")
        repo.pending_ref_recoveries.should be_empty
      end
    end
  end

  it "P18/19-O04 refuses stale refs and foreign locks before publishing the index" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      edits = GitIndexRefOracle.edits(fixture[:blob])
      index = File.join(root, ".git", "index")
      refs = GitIndexRefOracle.refs(fixture[:new_oid], fixture[:old_oid], fixture[:actor])
      expect_raises(Git::Error, /compare-and-swap/) do
        repo.change_index_and_refs_recoverably(edits, refs, id: "stale")
      end
      File.exists?(index).should be_false
      repo.pending_ref_recoveries.should be_empty
      correct_refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      File.write(File.join(root, ".git", "refs", "heads", "main.lock"), "foreign")
      expect_raises(Git::Error, /blocked by ref lock/) do
        repo.change_index_and_refs_recoverably(edits, correct_refs, id: "locked")
      end
      File.exists?(index).should be_false
      repo.pending_ref_recoveries.should be_empty
    end
  end

  it "P18/19-O05 refuses third-party index divergence before mutating refs" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::References::PartialPublication) do
        repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "diverged-index",
          after_index_publish: -> { raise "stop" })
      end
      before_ref = repo.resolve_ref?("refs/heads/main")
      repo.stage_blob("foreign.txt", "foreign")
      expected_index = File.read(File.join(root, ".git", "index"))
      expect_raises(Git::Error, /index recovery conflict/) { repo.recover_index_and_refs("diverged-index") }
      File.read(File.join(root, ".git", "index")).should eq(expected_index)
      repo.resolve_ref?("refs/heads/main").should eq(before_ref)
      repo.pending_ref_recoveries.should eq(["diverged-index"])
    end
  end

  it "P18/19-O06 refuses abandoned index.lock until explicit maintenance authorization" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::References::PartialPublication) do
        repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "abandoned-index",
          after_index_publish: -> { raise "stop" })
      end
      lock = File.join(root, ".git", "index.lock")
      File.write(lock, "abandoned")
      expect_raises(Git::Error, /blocked by index lock/) { repo.recover_index_and_refs("abandoned-index") }
      File.read(lock).should eq("abandoned")
      repo.recover_index_and_refs("abandoned-index", clear_abandoned_locks: true)
      File.exists?(lock).should be_false
      repo.resolve_ref?("refs/heads/main").should eq(fixture[:new_oid])
    end
  end

  ["locked", "published"].each do |phase|
    it "P18/19-O07 recovers a real _exit-killed index writer at #{phase} phase" do
      GitOracle.with_repo do |root|
        fixture = GitIndexRefOracle.fixture(root)
        child = Process.run(Process.executable_path.not_nil!, [] of String,
          env: {"CR_GIT_INDEX_REF_CRASH" => root, "CR_GIT_INDEX_REF_PHASE" => phase,
                "CR_GIT_INDEX_REF_BLOB" => fixture[:blob], "CR_GIT_INDEX_REF_OLD" => fixture[:old_oid],
                "CR_GIT_INDEX_REF_NEW" => fixture[:new_oid]},
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        child.exit_code.should eq(phase == "locked" ? 77 : 78)
        repo = fixture[:repo]
        repo.pending_ref_recoveries.should eq(["crashed-#{phase}"])
        if phase == "locked"
          expect_raises(Git::Error, /blocked by index lock/) { repo.recover_index_and_refs("crashed-locked") }
        end
        repo.recover_index_and_refs("crashed-#{phase}", clear_abandoned_locks: phase == "locked")
        repo.resolve_ref?("refs/heads/main").should eq(fixture[:new_oid])
        repo.write_index_tree.should eq(fixture[:tree])
        repo.pending_ref_recoveries.should be_empty
      end
    end
  end

  it "P18/19-O08 refuses a tampered v3 journal and preserves both surfaces" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::References::PartialPublication) do
        repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "tampered",
          after_index_publish: -> { raise "stop" })
      end
      journal = File.join(root, ".git", "crystal-git-recovery", "tampered.redo")
      File.open(journal, "a") { |io| io << "junk" }
      expect_raises(Git::Error, /checksum|envelope/) { repo.recover_index_and_refs("tampered") }
      repo.resolve_ref?("refs/heads/main").should eq(fixture[:old_oid])
      repo.pending_ref_recoveries.should eq(["tampered"])
    end
  end
end

describe "P18/P19 native staged commit with recoverable index and branch" do
  ["sha1", "sha256"].each do |format|
    it "P18/19-O09 writes #{format} tree, commit, index and branch from one prepared staging image" do
      GitOracle.with_repo(format: format) do |root|
        fixture = GitIndexRefOracle.fixture(root)
        repo = fixture[:repo]
        oid = repo.commit_index_changes_recoverably(GitIndexRefOracle.edits(fixture[:blob]),
          id: "commit-#{format}", author: fixture[:actor], committer: fixture[:actor], message: "joint commit")
        oid.should_not eq(fixture[:new_oid])
        repo.pending_ref_recoveries.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(oid)
        commit = repo.commit(oid, 8192) { nil }
        commit.parents.should eq([fixture[:old_oid]])
        commit.tree.should eq(repo.write_index_tree)
        GitOracle.run(root, "show", "--format=", "--name-only", "HEAD").stdout.should contain("joint.txt")
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end

    it "P18/19-O10 restores a #{format} prepared commit after interruption between index and branch" do
      GitOracle.with_repo(format: format) do |root|
        fixture = GitIndexRefOracle.fixture(root)
        repo = fixture[:repo]
        expect_raises(Git::References::PartialPublication) do
          repo.commit_index_changes_recoverably(GitIndexRefOracle.edits(fixture[:blob]),
            id: "interrupted-commit-#{format}", author: fixture[:actor], committer: fixture[:actor],
            message: "recover this commit", after_index_publish: -> { raise "interrupted" })
        end
        repo.resolve_ref?("refs/heads/main").should eq(fixture[:old_oid])
        repo.write_index_tree.should eq(fixture[:tree])
        repo.recover_index_and_refs("interrupted-commit-#{format}")
        head = repo.resolve_ref?("refs/heads/main").not_nil!
        repo.commit(head, 8192) { nil }.tree.should eq(fixture[:tree])
        GitOracle.run(root, "log", "-1", "--format=%s").stdout.strip.should eq("recover this commit")
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end
  end

  it "P18/19-O11 can create a first recoverable commit on an unborn branch" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      actor = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
      blob = repo.write_blob("initial\n")
      edits = [] of Git::Index::Edit
      edits << Git::Index::Put.new("initial.txt", "100644", blob)
      commit_oid = repo.commit_index_changes_recoverably(edits, id: "initial", author: actor,
        committer: actor, message: "initial commit")
      repo.head[1].should eq(commit_oid)
      repo.commit(commit_oid, 8192) { nil }.parents.should be_empty
      GitOracle.run(root, "ls-tree", "HEAD").stdout.should contain("initial.txt")
      GitOracle.run(root, "fsck", "--no-reflogs")
    end
  end
end

describe "P18/P19 coordinated index recovery failure boundaries" do
  it "P18/19-O12 refuses redirected index and an unsupported index image without changing refs" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      original_index = File.join(root, ".git", "index")
      File.write(original_index + ".original", "not an index")
      File.symlink(original_index + ".original", original_index)
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::Error) do
        repo.change_index_and_refs_recoverably(GitIndexRefOracle.edits(fixture[:blob]), refs, id: "redirected-index")
      end
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/main").should eq(fixture[:old_oid])
      File.read(original_index + ".original").should eq("not an index")
    end
  end

  it "P18/19-O13 refuses duplicate staged edits without touching the index or refs" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      edits = GitIndexRefOracle.edits(fixture[:blob])
      edits << Git::Index::Remove.new("joint.txt")
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::Error, /duplicate Git index change/) do
        repo.change_index_and_refs_recoverably(edits, refs, id: "duplicate-edit")
      end
      repo.pending_ref_recoveries.should be_empty
      repo.resolve_ref?("refs/heads/main").should eq(fixture[:old_oid])
      File.exists?(File.join(root, ".git", "index")).should be_false
    end
  end

  it "P18/19-O14 can remove and stage paths together and recover their exact tree" do
    GitOracle.with_repo do |root|
      fixture = GitIndexRefOracle.fixture(root)
      repo = fixture[:repo]
      repo.stage_blob("old.txt", "remove staged only\n")
      edits = GitIndexRefOracle.edits(fixture[:blob])
      edits << Git::Index::Remove.new("old.txt")
      refs = GitIndexRefOracle.refs(fixture[:old_oid], fixture[:new_oid], fixture[:actor])
      expect_raises(Git::References::PartialPublication) do
        repo.change_index_and_refs_recoverably(edits, refs, id: "remove-and-add",
          after_index_publish: -> { raise "stop" })
      end
      repo.recover_index_and_refs("remove-and-add")
      repo.write_index_tree.should eq(fixture[:tree])
      GitOracle.run(root, "ls-files", "--stage").stdout.should_not contain("old.txt")
      GitOracle.run(root, "fsck", "--no-reflogs")
    end
  end
end

it "P18/19-O15 refuses missing or wrong-type staged objects before durable branch publication" do
  GitOracle.with_repo do |root|
    repo = Git::Repository.new(root)
    actor = Git::Signature.new("Recovery", "recovery@example.invalid", 1_i64, 0)
    nil_oid = "f" * repo.object_format.hexsize
    bad = [] of Git::Index::Edit
    bad << Git::Index::Put.new("dangling.txt", "100644", nil_oid)
    expect_raises(Git::Error, /not available/) do
      repo.commit_index_changes_recoverably(bad, id: "missing-blob", author: actor,
        committer: actor, message: "would dangle")
    end
    tree = repo.write_tree([] of Git::Tree::Entry)
    bad[0] = Git::Index::Put.new("not-blob.txt", "100644", tree)
    expect_raises(Git::Error, /does not name a blob/) do
      repo.commit_index_changes_recoverably(bad, id: "wrong-kind", author: actor,
        committer: actor, message: "wrong kind")
    end
    repo.pending_ref_recoveries.should be_empty
    repo.head[1].should be_nil
    File.exists?(File.join(root, ".git", "index")).should be_false
  end
end
