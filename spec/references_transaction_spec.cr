require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P19 native single-reference compare-and-swap transaction" do
  ["sha1", "sha256"].each do |format|
    it "P19-O01 creates and updates a #{format} branch with Git-compatible CAS" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        tree = repo.write_tree([] of Git::Tree::Entry)
        sig = Git::Signature.new("Oracle", "oracle@example.invalid", 123_i64, 0)
        first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "first\n")
        second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "second\n")
        repo.update_ref("refs/heads/main", first, expected_oid: nil)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(first)
        expect_raises(Git::Error, /compare-and-swap/) { repo.update_ref("refs/heads/main", second, expected_oid: nil) }
        expect_raises(Git::Error, /compare-and-swap/) { repo.update_ref("refs/heads/main", second, expected_oid: "0" * repo.object_format.hexsize) }
        repo.update_ref("refs/heads/main", second, expected_oid: first)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(second)
        GitOracle.run(root, "fsck", "--no-reflogs")
        File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
      end
    end
  end

  it "P19-O02 preserves a foreign ref lock, refuses symlink and cancelled publication" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Oracle", "oracle@example.invalid", 123_i64, 0)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "first\n")
      target = File.join(root, ".git", "refs", "heads", "feature")
      File.write(target + ".lock", "foreign")
      expect_raises(Git::Error, /lock/) { repo.update_ref("refs/heads/feature", oid, expected_oid: nil) }
      File.read(target + ".lock").should eq("foreign")
      File.delete(target + ".lock")
      expect_raises(Git::Error, /cancelled/) do
        repo.update_ref("refs/heads/feature", oid, expected_oid: nil, check: -> { raise Git::Error.new("cancelled") })
      end
      File.exists?(target).should be_false
      File.exists?(target + ".lock").should be_false
      File.symlink(File.join(root, ".git", "HEAD"), target)
      expect_raises(Git::Error, /redirected/) { repo.update_ref("refs/heads/feature", oid, expected_oid: nil) }
    end
  end
end

describe "P19 packed references and reflogs" do
  it "P19-O04 shadows a packed ref and writes branch/HEAD reflogs" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Crystal", "crystal@example.invalid", 1_700_000_000_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      first = repo.write_commit(tree: tree, author: sig, committer: sig, message: "first")
      second = repo.write_commit(tree: tree, parents: [first], author: sig, committer: sig, message: "second")
      GitOracle.run(root, "update-ref", "refs/heads/main", first)
      GitOracle.run(root, "pack-refs", "--all")
      File.exists?(File.join(root, ".git", "refs", "heads", "main")).should be_false
      repo.update_ref("refs/heads/main", second, expected_oid: first,
        log: Git::References::LogEntry.new(sig, "test: native update"))
      GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(second)
      GitOracle.run(root, "reflog", "show", "--format=%gs", "HEAD").stdout.should contain("test: native update")
      GitOracle.run(root, "reflog", "show", "--format=%gs", "refs/heads/main").stdout.should contain("test: native update")
      oldlog = File.read(File.join(root, ".git", "logs", "HEAD"))
      expect_raises(Git::Error, /compare-and-swap/) do
        repo.update_ref("refs/heads/main", first, expected_oid: first,
          log: Git::References::LogEntry.new(sig, "stale"))
      end
      File.read(File.join(root, ".git", "logs", "HEAD")).should eq(oldlog)
      expect_raises(Git::Error) { repo.update_ref("refs/heads/another", "f" * 40, expected_oid: nil) }
      File.exists?(File.join(root, ".git", "refs", "heads", "another")).should be_false
    end
  end
end

describe "P19 coordinated native loose-reference transactions" do
  ["sha1", "sha256"].each do |format|
    it "P19-O07 creates and advances multiple #{format} refs and publishes reflogs" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        tree = repo.write_tree([] of Git::Tree::Entry)
        sig = Git::Signature.new("Batch", "batch@example.invalid", 1_700_000_000_i64, 0)
        a = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        b = repo.write_commit(tree: tree, parents: [a], author: sig, committer: sig, message: "two")
        log = Git::References::LogEntry.new(sig, "native: batch create")
        repo.update_refs([
          Git::References::Update.new("refs/heads/main", a, nil, log),
          Git::References::Update.new("refs/tags/snapshot", a, nil),
        ])
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(a)
        GitOracle.run(root, "rev-parse", "refs/tags/snapshot").stdout.strip.should eq(a)
        GitOracle.run(root, "reflog", "show", "--format=%gs", "HEAD").stdout.should contain("native: batch create")
        GitOracle.run(root, "pack-refs", "--all")
        log2 = Git::References::LogEntry.new(sig, "native: batch advance")
        repo.update_refs([
          Git::References::Update.new("refs/heads/main", b, a, log2),
          Git::References::Update.new("refs/tags/snapshot", b, a),
        ])
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(b)
        GitOracle.run(root, "rev-parse", "refs/tags/snapshot").stdout.strip.should eq(b)
        GitOracle.run(root, "fsck", "--no-reflogs")
        File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
      end
    end
  end

  it "P19-O08 rejects one stale expected OID before publishing any ref or reflog" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Batch", "batch@example.invalid", 1_i64, 0)
      a = repo.write_commit(tree: tree, author: sig, committer: sig, message: "a")
      b = repo.write_commit(tree: tree, parents: [a], author: sig, committer: sig, message: "b")
      repo.update_refs([
        Git::References::Update.new("refs/heads/main", a, nil),
        Git::References::Update.new("refs/heads/z-last", a, nil),
      ])
      original = GitOracle.run(root, "show-ref").stdout
      log = Git::References::LogEntry.new(sig, "must not appear")
      expect_raises(Git::Error, /compare-and-swap/) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/main", b, a, log),
          Git::References::Update.new("refs/heads/z-last", b, b, log),
        ])
      end
      GitOracle.run(root, "show-ref").stdout.should eq(original)
      File.exists?(File.join(root, ".git", "logs", "refs", "heads", "main")).should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "z-last.lock")).should be_false
    end
  end

  it "P19-O09 releases its earlier locks when a later foreign lock blocks preparation" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Batch", "batch@example.invalid", 1_i64, 0)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "a")
      first = File.join(root, ".git", "refs", "heads", "aaa.lock")
      foreign = File.join(root, ".git", "refs", "heads", "zzz.lock")
      File.write(foreign, "foreign")
      expect_raises(Git::Error, /lock/) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/zzz", oid, nil),
          Git::References::Update.new("refs/heads/aaa", oid, nil),
        ])
      end
      File.exists?(first).should be_false
      File.read(foreign).should eq("foreign")
      GitOracle.run(root, "show-ref", check: false).stdout.should eq("")
    end
  end

  it "P19-O10 rejects overlapping names, duplicate refs and invalid objects before side effects" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Batch", "batch@example.invalid", 1_i64, 0)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "a")
      expect_raises(Git::Error, /overlapping/) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/a", oid, nil),
          Git::References::Update.new("refs/heads/a/topic", oid, nil),
        ])
      end
      expect_raises(Git::Error, /overlapping/) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/a", oid, nil),
          Git::References::Update.new("refs/heads/a", oid, nil),
        ])
      end
      expect_raises(Git::Error) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/valid", oid, nil),
          Git::References::Update.new("refs/heads/invalid", "f" * 40, nil),
        ])
      end
      GitOracle.run(root, "show-ref", check: false).stdout.should eq("")
    end
  end
end

describe "P19 transaction preparation boundaries" do
  it "P19-O11 cancellation after every lock is held publishes no refs" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Batch", "batch@example.invalid", 1_i64, 0)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "a")
      first = File.join(root, ".git", "refs", "heads", "aaa.lock")
      second = File.join(root, ".git", "refs", "heads", "zzz.lock")
      saw_all_locks = false
      cancel = -> do
        if File.exists?(first) && File.exists?(second)
          saw_all_locks = true
          raise Git::Error.new("stopped after locking")
        end
      end
      expect_raises(Git::Error, /stopped after locking/) do
        repo.update_refs([
          Git::References::Update.new("refs/heads/aaa", oid, nil),
          Git::References::Update.new("refs/heads/zzz", oid, nil),
        ], check: cancel)
      end
      saw_all_locks.should be_true
      File.exists?(first).should be_false
      File.exists?(second).should be_false
      GitOracle.run(root, "show-ref", check: false).stdout.should eq("")
    end
  end
end

describe "P19 packed namespace collision protection" do
  it "P19-O12 rejects loose refs that would collide with a packed ancestor or descendant" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("Batch", "batch@example.invalid", 1_i64, 0)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "a")
      GitOracle.run(root, "update-ref", "refs/heads/top", oid)
      GitOracle.run(root, "update-ref", "refs/heads/deep/child", oid)
      GitOracle.run(root, "pack-refs", "--all")
      expect_raises(Git::Error, /namespace conflict/) do
        repo.update_refs([Git::References::Update.new("refs/heads/top/child", oid, nil)])
      end
      expect_raises(Git::Error, /namespace conflict/) do
        repo.update_refs([Git::References::Update.new("refs/heads/deep", oid, nil)])
      end
      GitOracle.run(root, "show-ref").stdout.lines.size.should eq(2)
    end
  end
end
