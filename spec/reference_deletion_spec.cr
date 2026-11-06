require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P19 native direct-reference deletion" do
  ["sha1", "sha256"].each do |format|
    it "P19-O13 deletes a loose #{format} branch by CAS and removes its reflog" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Delete", "delete@example.invalid", 1_700_000_000_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        ref = "refs/heads/review"
        repo.refs.update(ref, oid, expected_oid: nil, log: Git::References::LogEntry.new(sig, "create"))
        logfile = File.join(root, ".git", "logs", ref)
        File.exists?(logfile).should be_true
        repo.refs.delete(ref, expected_oid: oid)
        GitOracle.run(root, "show-ref", "--verify", ref, check: false).success?.should be_false
        File.exists?(logfile).should be_false
        File.exists?(File.join(root, ".git", "refs", "heads", "review.lock")).should be_false
        File.exists?(File.join(root, ".git", "packed-refs.lock")).should be_false
      end
    end

    it "P19-O14 deletes a packed #{format} annotated tag and its peeled line" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Delete", "delete@example.invalid", 1_700_000_000_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
        repo.refs.update("refs/heads/main", oid, expected_oid: nil)
        GitOracle.run(root, "tag", "-a", "v-one", "-m", "tag one")
        GitOracle.run(root, "tag", "-a", "v-two", "-m", "tag two")
        GitOracle.run(root, "pack-refs", "--all")
        packed = File.join(root, ".git", "packed-refs")
        before = File.read(packed)
        before.should contain("refs/tags/v-one")
        before.should contain("^#{oid}")
        tag_oid = GitOracle.run(root, "rev-parse", "refs/tags/v-one").stdout.strip
        repo.refs.delete("refs/tags/v-one", expected_oid: tag_oid)
        after = File.read(packed)
        after.should_not contain("refs/tags/v-one")
        after.should contain("refs/tags/v-two")
        # One peeled line should remain for the unrelated annotated tag.
        after.lines.count(&.starts_with?('^')).should eq(1)
        GitOracle.run(root, "show-ref", "--verify", "refs/tags/v-one", check: false).success?.should be_false
        GitOracle.run(root, "show-ref", "--verify", "refs/tags/v-two").success?.should be_true
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end
  end

  it "P19-O15 rejects stale OIDs and foreign packed locks without side effects" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Delete", "delete@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.refs.update("refs/heads/a", oid, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      before = File.read(packed)
      expect_raises(Git::Error, /compare-and-swap/) { repo.refs.delete("refs/heads/a", expected_oid: "0" * 40) }
      File.read(packed).should eq(before)
      File.write(packed + ".lock", "another writer")
      expect_raises(Git::Error, /packed-ref lock/) { repo.refs.delete("refs/heads/a", expected_oid: oid) }
      File.read(packed + ".lock").should eq("another writer")
      File.delete(packed + ".lock")
      File.read(packed).should eq(before)
    end
  end

  it "P19-O16 cancelled packed deletion leaves the branch and packed bytes unchanged" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Delete", "delete@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.refs.update("refs/heads/a", oid, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      before = File.read(packed)
      saw_locks = false
      check = -> do
        if File.exists?(packed + ".lock")
          saw_locks = true
          raise Git::Error.new("cancelled")
        end
      end
      expect_raises(Git::Error, /cancelled/) { repo.refs.delete("refs/heads/a", expected_oid: oid, check: check) }
      saw_locks.should be_true
      File.read(packed).should eq(before)
      GitOracle.run(root, "show-ref", "--verify", "refs/heads/a").success?.should be_true
      File.exists?(packed + ".lock").should be_false
      File.exists?(File.join(root, ".git", "refs", "heads", "a.lock")).should be_false
    end
  end

  it "P19-O17 fails closed on a redirected reflog or bounded packed table" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Delete", "delete@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.refs.update("refs/heads/a", oid, expected_oid: nil)
      reflog = File.join(root, ".git", "logs", "refs", "heads", "a")
      Dir.mkdir_p(File.dirname(reflog))
      File.symlink(File.join(root, "elsewhere"), reflog)
      expect_raises(Git::Error, /reflog redirected/) { repo.refs.delete("refs/heads/a", expected_oid: oid) }
      File.exists?(File.join(root, ".git", "refs", "heads", "a")).should be_true
      File.delete(reflog)
      5.times do |n|
        repo.refs.update("refs/heads/extra#{n}", oid, expected_oid: nil)
      end
      GitOracle.run(root, "pack-refs", "--all")
      packed = File.join(root, ".git", "packed-refs")
      before = File.read(packed)
      expect_raises(Git::Error, /budget exceeded/) do
        repo.refs.delete("refs/heads/a", expected_oid: oid, max_packed_bytes: 128)
      end
      File.read(packed).should eq(before)
    end
  end
end

describe "P19 packed-and-loose deletion coherency" do
  it "P19-O18 does not expose a shadowed packed value after deleting a loose update" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Delete", "delete@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      old_oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
      new_oid = repo.write_commit(tree: tree, parents: [old_oid], author: sig, committer: sig, message: "new")
      ref = "refs/heads/shadow"
      repo.refs.update(ref, old_oid, expected_oid: nil)
      GitOracle.run(root, "pack-refs", "--all")
      repo.refs.update(ref, new_oid, expected_oid: old_oid)
      GitOracle.run(root, "rev-parse", ref).stdout.strip.should eq(new_oid)
      expect_raises(Git::Error, /compare-and-swap/) { repo.refs.delete(ref, expected_oid: old_oid) }
      repo.refs.delete(ref, expected_oid: new_oid)
      GitOracle.run(root, "show-ref", "--verify", ref, check: false).success?.should be_false
      File.read(File.join(root, ".git", "packed-refs")).should_not contain(ref)
    end
  end

  it "P19-O19 refuses malformed packed refs and symbolic loose refs without deletion" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Delete", "delete@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      oid = repo.write_commit(tree: tree, author: sig, committer: sig, message: "one")
      repo.refs.update("refs/heads/a", oid, expected_oid: nil)
      packed = File.join(root, ".git", "packed-refs")
      File.write(packed, "# test\n^#{oid}\n")
      before = File.read(packed)
      expect_raises(Git::Error, /peeled ref/) { repo.refs.delete("refs/heads/a", expected_oid: oid) }
      File.read(packed).should eq(before)
      File.delete(packed)
      File.write(File.join(root, ".git", "refs", "heads", "a"), "ref: refs/heads/target\n")
      expect_raises(Git::Error, /symbolic/) { repo.refs.delete("refs/heads/a", expected_oid: oid) }
    end
  end
end
