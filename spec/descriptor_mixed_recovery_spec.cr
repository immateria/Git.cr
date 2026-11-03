require "spec"
require "../src/git"
require "./support/git_oracle"

# P21: multiple-ref and journal paths must never follow a replaced Git parent
# into an attacker-controlled directory. All files are local isolated oracles.
describe "P21 descriptor-pinned mixed refs and recovery journals" do
  ["sha1", "sha256"].each do |format|
    it "P21-O01 refuses mixed publication after a ref parent swap (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "desired")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        repo.update_ref("refs/heads/obsolete", old, expected_oid: nil)
        heads = File.join(root, ".git", "refs", "heads")
        moved = heads + "-pinned"
        outside = File.join(root, "foreign")
        Dir.mkdir(outside)
        packed_lock = File.join(root, ".git", "packed-refs.lock")
        changed = false
        check = -> do
          if !changed && File.file?(packed_lock) && File.file?(File.join(heads, "main.lock")) && File.file?(File.join(heads, "obsolete.lock"))
            File.rename(heads, moved)
            File.symlink(outside, heads)
            File.write(File.join(outside, "main.lock"), "foreign")
            changed = true
          end
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        changes << Git::References::Delete.new("refs/heads/obsolete", old)
        begin
          expect_raises(Git::Error) { repo.change_refs(changes, check: check) }
          changed.should be_true
          File.read(File.join(outside, "main.lock")).should eq("foreign")
          File.exists?(File.join(moved, "main.lock")).should be_false
          File.exists?(File.join(moved, "obsolete.lock")).should be_false
          File.exists?(packed_lock).should be_false
        ensure
          File.delete(heads) if File.symlink?(heads)
          File.rename(moved, heads) if Dir.exists?(moved)
        end
        repo.resolve_ref?("refs/heads/main").should eq(old)
        repo.resolve_ref?("refs/heads/obsolete").should eq(old)
      end
    end

    it "P21-O02 never cleans a foreign packed lock after a common-directory swap (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        repo.update_ref("refs/heads/obsolete", old, expected_oid: nil)
        gitdir = File.join(root, ".git")
        moved = File.join(root, ".git-original")
        outside = File.join(root, "outside")
        Dir.mkdir(outside)
        changed = false
        check = -> do
          if !changed && File.file?(File.join(gitdir, "packed-refs.lock"))
            File.rename(gitdir, moved)
            File.symlink(outside, gitdir)
            File.write(File.join(outside, "packed-refs.lock"), "foreign packed lock")
            changed = true
          end
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        changes << Git::References::Delete.new("refs/heads/obsolete", old)
        begin
          expect_raises(Git::Error) { repo.change_refs(changes, check: check) }
          changed.should be_true
          File.read(File.join(outside, "packed-refs.lock")).should eq("foreign packed lock")
          File.exists?(File.join(moved, "packed-refs.lock")).should be_false
        ensure
          File.delete(gitdir) if File.symlink?(gitdir)
          File.rename(moved, gitdir) if Dir.exists?(moved)
        end
        repo.resolve_ref?("refs/heads/main").should eq(old)
        repo.resolve_ref?("refs/heads/obsolete").should eq(old)
      end
    end

    it "P21-O03 preserves a replaced ref lock of identical bytes (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        lock = File.join(root, ".git", "refs", "heads", "main.lock")
        changed = false
        check = -> do
          if !changed && File.file?(lock)
            bytes = File.read(lock)
            File.rename(lock, lock + ".held")
            File.write(lock, bytes)
            changed = true
          end
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        expect_raises(Git::Error, /lock ownership changed/) { repo.change_refs(changes, check: check) }
        changed.should be_true
        File.exists?(lock).should be_true
        repo.resolve_ref?("refs/heads/main").should eq(old)
      end
    end

    it "P21-O04 preserves a redo journal when an ancestor becomes a symlink (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        recovery = File.join(root, ".git", "crystal-git-recovery")
        moved = recovery + "-pinned"
        outside = File.join(root, "outside")
        Dir.mkdir(outside)
        changed = false
        observer = ->(_name : String) do
          unless changed
            File.rename(recovery, moved)
            File.symlink(outside, recovery)
            File.write(File.join(outside, "moved.redo"), "foreign journal")
            changed = true
          end
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        begin
          expect_raises(Git::References::PartialPublication) do
            repo.change_refs_recoverably(changes, id: "moved", after_publish: observer)
          end
          changed.should be_true
          File.file?(File.join(moved, "moved.redo")).should be_true
          File.read(File.join(outside, "moved.redo")).should eq("foreign journal")
        ensure
          File.delete(recovery) if File.symlink?(recovery)
          File.rename(moved, recovery) if Dir.exists?(moved)
        end
        repo.recover_refs("moved")
        repo.resolve_ref?("refs/heads/main").should eq(desired)
        repo.pending_ref_recoveries.should be_empty
      end
    end

    it "P21-O05 never deletes a different redo inode even with identical contents (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        redo = File.join(root, ".git", "crystal-git-recovery", "swapped.redo")
        changed = false
        observer = ->(_name : String) do
          bytes = File.read(redo)
          File.rename(redo, redo + ".held")
          File.write(redo, bytes)
          changed = true
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        expect_raises(Git::References::PartialPublication) do
          repo.change_refs_recoverably(changes, id: "swapped", after_publish: observer)
        end
        changed.should be_true
        File.file?(redo).should be_true
        repo.pending_ref_recoveries.should contain("swapped")
        repo.recover_refs("swapped")
        repo.resolve_ref?("refs/heads/main").should eq(desired)
      end
    end

    it "P21-O06 preserves a foreign replacement finalization receipt (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        meta = Git::Metadata.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        receipt = File.join(root, ".git", "crystal-git-recovery", "receipt.finish")
        changed = false
        after_unlink = -> do
          bytes = File.read(receipt)
          File.rename(receipt, receipt + ".held")
          File.write(receipt, bytes)
          changed = true
          nil
        end
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        Git::References::Recovery.run(meta, repo.object_format, "receipt", changes,
          after_journal_unlink: after_unlink) do |pending|
          repo.change_refs(pending)
        end
        changed.should be_true
        File.file?(receipt).should be_true
        repo.pending_ref_finalizations.should contain("receipt")
        repo.finish_ref_finalization("receipt")
        repo.pending_ref_finalizations.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(desired)
      end
    end
    it "P21-O07 refuses orphan-receipt deletion after its parent is replaced (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        meta = Git::Metadata.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        recovery = File.join(root, ".git", "crystal-git-recovery")
        receipt = File.join(recovery, "orphan.finish")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        # Leave a valid receipt behind by replacing the initial receipt inode.
        on_unlink = -> do
          File.rename(receipt, receipt + ".held")
          File.write(receipt, File.read(receipt + ".held"))
          nil
        end
        Git::References::Recovery.run(meta, repo.object_format, "orphan", changes,
          after_journal_unlink: on_unlink) do |pending|
          repo.change_refs(pending)
        end
        moved = recovery + "-pinned"
        outside = File.join(root, "outside")
        Dir.mkdir(outside)
        relocated = false
        after_validation = -> do
          File.rename(recovery, moved)
          File.symlink(outside, recovery)
          File.write(File.join(outside, "orphan.finish"), "foreign receipt")
          relocated = true
          nil
        end
        begin
          expect_raises(Git::References::Recovery::Conflict) do
            Git::References::Recovery.finish_finalization(meta, repo.object_format,
              "orphan", after_validation: after_validation)
          end
          relocated.should be_true
          File.read(File.join(outside, "orphan.finish")).should eq("foreign receipt")
          File.file?(File.join(moved, "orphan.finish")).should be_true
        ensure
          File.delete(recovery) if File.symlink?(recovery)
          File.rename(moved, recovery) if Dir.exists?(moved)
        end
        repo.finish_ref_finalization("orphan")
        repo.pending_ref_finalizations.should be_empty
      end
    end
    it "P21-O08 rejects replacement of an orphan receipt after state validation (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        meta = Git::Metadata.new(root)
        sig = Git::Signature.new("Pin", "pin@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: sig, committer: sig, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: sig, committer: sig, message: "new")
        repo.update_ref("refs/heads/main", old, expected_oid: nil)
        receipt = File.join(root, ".git", "crystal-git-recovery", "leaf.finish")
        changes = [] of Git::References::Change
        changes << Git::References::Update.new("refs/heads/main", desired, old)
        on_unlink = -> do
          File.rename(receipt, receipt + ".initial")
          File.write(receipt, File.read(receipt + ".initial"))
          nil
        end
        Git::References::Recovery.run(meta, repo.object_format, "leaf", changes,
          after_journal_unlink: on_unlink) do |pending|
          repo.change_refs(pending)
        end
        replacement = false
        after_validation = -> do
          File.rename(receipt, receipt + ".held")
          File.write(receipt, File.read(receipt + ".held"))
          replacement = true
          nil
        end
        expect_raises(Git::References::Recovery::Conflict, /receipt inode replaced/) do
          Git::References::Recovery.finish_finalization(meta, repo.object_format,
            "leaf", after_validation: after_validation)
        end
        replacement.should be_true
        File.file?(receipt).should be_true
        repo.pending_ref_finalizations.should contain("leaf")
        repo.finish_ref_finalization("leaf")
        repo.pending_ref_finalizations.should be_empty
        repo.resolve_ref?("refs/heads/main").should eq(desired)
      end
    end
  end
end
