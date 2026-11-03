require "spec"
require "../src/git"
require "./support/git_oracle"
require "c/sys/file"

# This child exits without ensure to leave a genuine finalization receipt.
if root = ENV["CR_GIT_DESCRIPTOR_RECEIPT_CHILD"]?
  repo = Git::Repository.new(root)
  meta = Git::Metadata.new(root)
  old = ENV["CR_GIT_DESCRIPTOR_OLD"]
  desired = ENV["CR_GIT_DESCRIPTOR_NEW"]
  changes = [] of Git::References::Change
  changes << Git::References::Update.new("refs/heads/main", desired, old)
  Git::References::Recovery.run(meta, repo.object_format, "confined-final", changes,
    after_journal_unlink: -> { LibC._exit(89); nil }) do |pending|
    repo.refs.apply(pending)
  end
  LibC._exit(88)
end

describe "P20 descriptor-confined Git mutation" do
  ["sha1", "sha256"].each do |format|
    it "P20-O01 unlinks only in the pinned directory after a symlink parent swap (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        path = File.join(root, ".git", "refs", "heads", "test.lock")
        parent = File.dirname(path)
        moved = parent + "-moved"
        foreign = File.join(root, "foreign")
        Dir.mkdir(foreign)
        dir, name = Git::DescriptorPath::Directory.open_parent(path)
        begin
          io = dir.open_file(name, LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          begin
            io.write("our lock".to_slice)
            io.flush
            io.fsync
            File.rename(parent, moved)
            File.symlink(foreign, parent)
            File.write(File.join(foreign, name), "foreign lock")
            dir.attached_at?(parent).should be_false
            dir.same_inode?(name, io).should be_true
            dir.unlink(name)
            dir.sync
            File.exists?(File.join(moved, name)).should be_false
            File.read(File.join(foreign, name)).should eq("foreign lock")
          ensure
            io.close unless io.closed?
          end
        ensure
          dir.close
          File.delete(parent) if File.symlink?(parent)
          File.rename(moved, parent) if Dir.exists?(moved)
        end
      end
    end

    it "P20-O02 renames only inside a pinned directory after its path is replaced (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        parent = File.join(root, ".git", "refs", "heads")
        moved = parent + "-moved"
        foreign = File.join(root, "foreign")
        Dir.mkdir(foreign)
        dir = Git::DescriptorPath::Directory.open(parent)
        begin
          io = dir.open_file("branch.lock", LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          io.write("ours".to_slice)
          io.close
          File.rename(parent, moved)
          File.symlink(foreign, parent)
          File.write(File.join(foreign, "branch"), "foreign branch")
          dir.rename("branch.lock", "branch")
          dir.sync
          File.read(File.join(moved, "branch")).should eq("ours")
          File.read(File.join(foreign, "branch")).should eq("foreign branch")
        ensure
          dir.close
          File.delete(parent) if File.symlink?(parent)
          File.rename(moved, parent) if Dir.exists?(moved)
        end
      end
    end

    it "P20-O03 refuses symlinked ancestors rather than opening an outside lock (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        parent = File.join(root, ".git", "refs", "heads")
        moved = parent + "-moved"
        outside = File.join(root, "outside")
        Dir.mkdir(outside)
        File.rename(parent, moved)
        File.symlink(outside, parent)
        begin
          expect_raises(Git::Error, /parent missing or redirected/) do
            Git::DescriptorPath::Directory.open_parent(File.join(parent, "main.lock"))
          end
          File.write(File.join(outside, "main.lock"), "foreign")
          expect_raises(Git::Error, /parent missing or redirected/) do
            Git::DescriptorPath::Directory.with_parent(File.join(parent, "main.lock")) do |dir, name|
              dir.unlink(name)
            end
          end
          File.read(File.join(outside, "main.lock")).should eq("foreign")
        ensure
          File.delete(parent)
          File.rename(moved, parent)
        end
      end
    end

    it "P20-O04 rejects a replaced lock inode even if the replacement has identical bytes (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        path = File.join(root, ".git", "refs", "heads", "mine.lock")
        dir, name = Git::DescriptorPath::Directory.open_parent(path)
        begin
          io = dir.open_file(name, LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          begin
            io.write("same bytes".to_slice)
            io.flush
            File.delete(path)
            File.write(path, "same bytes")
            dir.same_inode?(name, io).should be_false
            File.read(path).should eq("same bytes")
          ensure
            io.close
          end
        ensure
          dir.close
        end
      end
    end

    it "P20-O05 refuses single-ref publication if the pinned ref parent is detached (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Ref", "ref@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "new")
        repo.refs.update("refs/heads/main", old, expected_oid: nil)
        parent = File.join(root, ".git", "refs", "heads")
        moved = parent + "-moved"
        changed = false
        lock_checks = 0
        check = -> {
          lock_checks += 1 if File.file?(File.join(parent, "main.lock"))
          if !changed && lock_checks == 2
            File.rename(parent, moved)
            Dir.mkdir(parent) # A real new directory, not a symlink
            File.write(File.join(parent, "main"), "#{old}\n")
            File.write(File.join(parent, "main.lock"), "foreign")
            changed = true
          end
          nil
        }
        begin
          expect_raises(Git::Error, /parent replaced/) do
            repo.refs.update("refs/heads/main", desired, expected_oid: old, check: check)
          end
          File.read(File.join(parent, "main.lock")).should eq("foreign")
          File.read(File.join(moved, "main")).should eq("#{old}\n")
          File.exists?(File.join(moved, "main.lock")).should be_false
        ensure
          if changed && Dir.exists?(parent)
            File.delete(File.join(parent, "main.lock"))
            File.delete(File.join(parent, "main"))
            Dir.delete(parent)
          end
          File.rename(moved, parent) if Dir.exists?(moved)
        end
        repo.refs.resolve?("refs/heads/main").should eq(old)
      end
    end

    it "P20-O06 rejects symlinked index parents and never removes an outside index lock (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        repo.stage_blob("first", "value")
        gitdir = File.join(root, ".git")
        moved = File.join(root, ".git-pinned")
        foreign = File.join(root, "outside")
        Dir.mkdir(foreign)
        File.write(File.join(foreign, "index.lock"), "foreign")
        before = File.read(File.join(gitdir, "index"))
        changed = false
        check = -> {
          if !changed && File.file?(File.join(gitdir, "index.lock"))
            File.rename(gitdir, moved)
            File.symlink(foreign, gitdir)
            changed = true
          end
          nil
        }
        begin
          expect_raises(Git::Error) { repo.stage_blob("next", "value2", check: check) }
          changed.should be_true
          File.read(File.join(foreign, "index.lock")).should eq("foreign")
          File.read(File.join(moved, "index")).should eq(before)
          File.exists?(File.join(moved, "index.lock")).should be_false
        ensure
          File.delete(gitdir) if File.symlink?(gitdir)
          File.rename(moved, gitdir) if Dir.exists?(moved)
        end
      end
    end

    it "P20-O07 preserves an orphan receipt when the ref parent detaches after validation (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Ref", "ref@example.invalid", 100_i64, 0)
        tree = repo.write_tree([] of Git::Tree::Entry)
        old = repo.write_commit(tree: tree, author: actor, committer: actor, message: "old")
        desired = repo.write_commit(tree: tree, parents: [old], author: actor, committer: actor, message: "new")
        repo.refs.update("refs/heads/main", old, expected_oid: nil)
        status = Process.run(Process.executable_path.not_nil!, [] of String,
          env: {"CR_GIT_DESCRIPTOR_RECEIPT_CHILD" => root, "CR_GIT_DESCRIPTOR_OLD" => old,
                "CR_GIT_DESCRIPTOR_NEW" => desired},
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        status.exit_code.should eq(89)
        repo.recovery.pending_finalizations.should eq(["confined-final"])
        parent = File.join(root, ".git", "refs", "heads")
        moved = parent + "-moved"
        outside = File.join(root, "outside")
        Dir.mkdir(outside)
        callback = -> {
          File.rename(parent, moved)
          File.symlink(outside, parent)
          File.write(File.join(outside, "main.lock"), "foreign")
          nil
        }
        begin
          meta = Git::Metadata.new(root)
          expect_raises(Git::References::Recovery::Conflict, /parent replaced/) do
            Git::References::Recovery.finish_finalization(meta, repo.object_format, "confined-final", callback)
          end
          File.read(File.join(outside, "main.lock")).should eq("foreign")
          File.file?(File.join(moved, "main.lock")).should be_true
          repo.recovery.pending_finalizations.should eq(["confined-final"])
        ensure
          File.delete(parent) if File.symlink?(parent)
          File.rename(moved, parent) if Dir.exists?(moved)
        end
        repo.recovery.finish_finalization("confined-final")
        repo.recovery.pending_finalizations.should be_empty
        repo.refs.resolve?("refs/heads/main").should eq(desired)
      end
    end

    it "P20-O08 refuses rename_noreplace over an existing leaf and keeps both files (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        parent = File.join(root, ".git", "refs", "heads")
        dir = Git::DescriptorPath::Directory.open(parent)
        begin
          io = dir.open_file("temp.lock", LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          io.write("ours".to_slice)
          io.close
          io = dir.open_file("branch", LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          io.write("theirs".to_slice)
          io.close
          expect_raises(Git::Error, /destination appeared during publication/) do
            dir.rename_noreplace("temp.lock", "branch")
          end
          File.read(File.join(parent, "branch")).should eq("theirs")
          File.read(File.join(parent, "temp.lock")).should eq("ours")
          dir.rename_noreplace("temp.lock", "fresh")
          File.read(File.join(parent, "fresh")).should eq("ours")
          File.exists?(File.join(parent, "temp.lock")).should be_false
        ensure
          dir.close
        end
      end
    end

    it "P20-O09 refuses to open a regular file as a directory (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        parent = File.join(root, ".git", "refs", "heads")
        dir = Git::DescriptorPath::Directory.open(parent)
        begin
          io = dir.open_file("leaf", LibC::O_CREAT | LibC::O_EXCL | LibC::O_WRONLY)
          io.write("x".to_slice)
          io.close
          expect_raises(Git::Error, /parent missing or redirected: leaf/) do
            Git::DescriptorPath::Directory.open(File.join(parent, "leaf"))
          end
          expect_raises(Git::Error, /child directory unavailable or redirected: leaf/) do
            dir.open_directory("leaf")
          end
        ensure
          dir.close
        end
      end
    end
  end
end
