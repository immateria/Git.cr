require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P19 native mixed-reference transactions" do
  ["sha1", "sha256"].each do |format|
    it "P19-O20 prepares #{format} ref updates, creations, loose/packed deletes and peeled-tag removal together" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Mixed", "mixed@example.invalid", 1_700_000_000_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        one = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        two = repo.write_commit(tree: tree, parents: [one], author: sig, committer: sig, message: "two")
        log = Git::References::LogEntry.new(sig, "native mixed update")
        repo.update_ref("refs/heads/main", one, expected_oid: nil, log: log)
        repo.update_ref("refs/heads/obsolete", one, expected_oid: nil, log: log)
        GitOracle.run(root, "tag", "-a", "release-one", "-m", "release one")
        GitOracle.run(root, "tag", "-a", "release-two", "-m", "release two")
        tag_oid = GitOracle.run(root, "rev-parse", "refs/tags/release-one").stdout.strip
        GitOracle.run(root, "pack-refs", "--all")
        # A loose override shadows the packed commit. Both copies must go.
        repo.update_ref("refs/heads/obsolete", two, expected_oid: one)
        packed = File.join(root, ".git", "packed-refs")
        File.read(packed).should contain("refs/heads/obsolete")
        File.read(packed).should contain("refs/tags/release-one")
        changes = [] of Git::References::Change
        changes << Git::References::Delete.new("refs/heads/obsolete", two)
        changes << Git::References::Update.new("refs/heads/main", two, one, log)
        changes << Git::References::Delete.new("refs/tags/release-one", tag_oid)
        changes << Git::References::Update.new("refs/tags/preview", one, nil)
        published = [] of String
        observer = ->(name : String) { published << name; nil }
        repo.change_refs(changes, after_publish: observer)
        published.should eq(changes.map(&.name).sort)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(two)
        GitOracle.run(root, "rev-parse", "refs/tags/preview").stdout.strip.should eq(one)
        GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete", check: false).success?.should be_false
        GitOracle.run(root, "show-ref", "--verify", "refs/tags/release-one", check: false).success?.should be_false
        GitOracle.run(root, "show-ref", "--verify", "refs/tags/release-two").success?.should be_true
        after = File.read(packed)
        after.should_not contain("refs/heads/obsolete")
        after.should_not contain("refs/tags/release-one")
        after.lines.count(&.starts_with?('^')).should eq(1)
        File.exists?(File.join(root, ".git", "logs", "refs", "heads", "obsolete")).should be_false
        GitOracle.run(root, "reflog", "show", "--format=%gs", "HEAD").stdout.should contain("native mixed update")
        GitOracle.run(root, "fsck", "--no-reflogs")
        File.exists?(packed + ".lock").should be_false
        changes.each do |change|
          File.exists?(File.join(root, ".git", change.name + ".lock")).should be_false
        end
      end
    end
  end

  it "P19-O21 refuses a stale deletion and preserves every ref, packed byte and reflog" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      one = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      two = repo.write_commit(tree: tree, parents: [one], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/main", one, expected_oid: nil)
      repo.update_ref("refs/heads/obsolete", one, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      before = File.read(packed)
      refs = GitOracle.run(root, "show-ref").stdout
      bad = [] of Git::References::Change
      bad << Git::References::Update.new("refs/heads/main", two, one,
        Git::References::LogEntry.new(sig, "should never appear"))
      bad << Git::References::Delete.new("refs/heads/obsolete", two)
      expect_raises(Git::Error, /compare-and-swap/) { repo.change_refs(bad) }
      GitOracle.run(root, "show-ref").stdout.should eq(refs)
      File.read(packed).should eq(before)
      File.exists?(packed + ".lock").should be_false
      File.exists?(File.join(root, ".git", "logs", "refs", "heads", "main")).should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "obsolete.lock")).should be_false
    end
  end

  it "P19-O22 refuses a foreign packed lock without replacing it or publishing updates" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.update_ref("refs/heads/obsolete", oid, expected_oid: nil)
      packed_lock = File.join(root, ".git", "packed-refs.lock")
      File.write(packed_lock, "foreign owner")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/a-new", oid, nil)
      changes << Git::References::Delete.new("refs/heads/obsolete", oid)
      expect_raises(Git::Error, /packed-ref lock/) { repo.change_refs(changes) }
      File.read(packed_lock).should eq("foreign owner")
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/a-new", check: false).success?.should be_false
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete").success?.should be_true
      File.exists?(File.join(root, ".git", "refs", "heads", "a-new.lock")).should be_false
    end
  end

  it "P19-O23 cancellation after every ref and packed lock leaves refs and logs untouched" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.update_ref("refs/heads/obsolete", oid, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      before = File.read(packed)
      first = File.join(root, ".git", "refs", "heads", "a-new.lock")
      second = File.join(root, ".git", "refs", "heads", "obsolete.lock")
      saw_locks = false
      cancel = -> do
        if File.exists?(packed + ".lock") && File.exists?(first) && File.exists?(second)
          saw_locks = true
          raise Git::Error.new("cancelled after all locks")
        end
      end
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/a-new", oid, nil)
      changes << Git::References::Delete.new("refs/heads/obsolete", oid)
      expect_raises(Git::Error, /cancelled after all locks/) { repo.change_refs(changes, check: cancel) }
      saw_locks.should be_true
      File.read(packed).should eq(before)
      File.exists?(packed + ".lock").should be_false
      File.exists?(first).should be_false
      File.exists?(second).should be_false
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/a-new", check: false).success?.should be_false
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete").success?.should be_true
    end
  end

  it "P19-O25 reports a partial publication when a post-publication observer fails" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      one = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      two = repo.write_commit(tree: tree, parents: [one], author: sig, committer: sig, message: "two")
      log = Git::References::LogEntry.new(sig, "mixed partial")
      repo.update_ref("refs/heads/obsolete", one, expected_oid: nil, log: log)
      repo.update_ref("refs/heads/main", one, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", two, one, log)
      changes << Git::References::Delete.new("refs/heads/obsolete", one)
      observer = ->(name : String) do
        raise Git::Error.new("simulated post-publication failure") if name == "refs/heads/main"
      end
      ex = expect_raises(Git::References::PartialPublication) do
        repo.change_refs(changes, after_publish: observer)
      end
      ex.packed_published.should be_true
      ex.reflogs_started.should be_true
      ex.published_refs.should eq(["refs/heads/main"])
      GitOracle.run(root, "rev-parse", "refs/heads/main").stdout.strip.should eq(two)
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/obsolete", check: false).success?.should be_false
      File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "obsolete.lock")).should be_false
    end
  end

  it "P19-O26 fails preparation on a redirected deletion reflog without publishing another update" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      one = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      two = repo.write_commit(tree: tree, parents: [one], author: sig, committer: sig, message: "two")
      repo.update_ref("refs/heads/main", one, expected_oid: nil)
      repo.update_ref("refs/heads/obsolete", one, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      packed_before = File.read(packed)
      logpath = File.join(root, ".git", "logs", "refs", "heads", "obsolete")
      Dir.mkdir_p(File.dirname(logpath))
      File.symlink(File.join(root, "outside"), logpath)
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/main", two, one)
      changes << Git::References::Delete.new("refs/heads/obsolete", one)
      expect_raises(Git::Error, /reflog redirected/) { repo.change_refs(changes) }
      File.read(packed).should eq(packed_before)
      GitOracle.run(root, "rev-parse", "refs/heads/main").stdout.strip.should eq(one)
      GitOracle.run(root, "rev-parse", "refs/heads/obsolete").stdout.strip.should eq(one)
      File.exists?(packed + ".lock").should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
    end
  end

  it "P19-O24 rejects duplicate or overlapping mutations, invalid new objects and short budgets" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Mixed", "mixed@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      changes = [] of Git::References::Change
      changes << Git::References::Update.new("refs/heads/a", oid, nil)
      changes << Git::References::Delete.new("refs/heads/a", oid)
      expect_raises(Git::Error, /overlapping/) { repo.change_refs(changes) }
      overlapping = [] of Git::References::Change
      overlapping << Git::References::Update.new("refs/heads/a", oid, nil)
      overlapping << Git::References::Delete.new("refs/heads/a/nested", oid)
      expect_raises(Git::Error, /overlapping/) { repo.change_refs(overlapping) }
      invalid = [] of Git::References::Change
      invalid << Git::References::Update.new("refs/heads/new", "f" * 40, nil)
      invalid << Git::References::Delete.new("refs/heads/a", oid)
      expect_raises(Git::Error) { repo.change_refs(invalid) }
      expect_raises(Git::Error, /budget exceeded/) { repo.change_refs(changes, max_changes: 1) }
      GitOracle.run(root, "show-ref", check: false).stdout.should eq("")
    end
  end
end
