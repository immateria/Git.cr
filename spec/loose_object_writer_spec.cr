require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P17 native Git loose-object writes" do
  ["sha1", "sha256"].each do |format|
    it "P17-O01 creates byte-exact #{format} loose blobs that real Git can read" do
      GitOracle.with_repo(format: format) do |root|
        payload = String.new(Bytes[0_u8, 255_u8, 128_u8, 65_u8, 10_u8, 0_u8, 42_u8])
        repo = Git::Repository.new(root)
        expected = GitOracle.run(root, "hash-object", "--stdin", input: payload).stdout.strip
        oid = repo.write_blob(payload.to_slice)
        oid.should eq(expected)
        repo.read_object(oid, max_bytes: 4096).should eq(Git::RawObject.new(Git::ObjectType::Blob, payload))
        GitOracle.assert_bytes!(GitOracle.run(root, "cat-file", "blob", oid).stdout, payload, "P17-O01")
        path = File.join(root, ".git", "objects", oid.byte_slice(0, 2), oid.byte_slice(2, oid.bytesize - 2))
        File.file?(path).should be_true
        File.info(path).permissions.value.should be < 0o666
        Dir.children(File.dirname(path)).should eq([File.basename(path)])
        # A second publication is idempotent and does not replace a valid inode.
        info = File.info(path)
        repo.write_blob(payload).should eq(oid)
        File.info(path).same_file?(info).should be_true
        GitOracle.run(root, "fsck", "--no-reflogs", "--unreachable", check: true)
      end
    end
  end

  it "P17-O07 writes to shared object storage from linked and bare worktrees" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "base.txt"), "base")
      GitOracle.run(root, "add", "base.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      linked = File.join(File.dirname(root), "linked")
      GitOracle.run(root, "worktree", "add", "-q", "-b", "feature", linked)
      linked_repo = Git::Repository.new(linked)
      linked_oid = linked_repo.write_blob("shared object")
      main_obj = File.join(root, ".git", "objects", linked_oid.byte_slice(0, 2), linked_oid.byte_slice(2, linked_oid.bytesize - 2))
      File.file?(main_obj).should be_true
      GitOracle.run(root, "cat-file", "blob", linked_oid).stdout.should eq("shared object")
      GitOracle.run(linked, "cat-file", "blob", linked_oid).stdout.should eq("shared object")
      bare = File.join(File.dirname(root), "bare.git")
      GitOracle.run(root, "clone", "--bare", "-q", root, bare)
      bare_repo = Git::Repository.new(bare)
      bare_repo.bare?.should be_true
      bare_oid = bare_repo.write_blob("bare object")
      GitOracle.run(bare, "cat-file", "blob", bare_oid).stdout.should eq("bare object")
    end
  end

  it "P17-O02 rejects input over its caller-supplied budget before writing" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      expect_raises(Git::Error, /budget/) { repo.write_blob("too large", max_bytes: 4) }
      expect_raises(ArgumentError, /budget/) { repo.write_blob("x", max_bytes: -1) }
      oid = Git::ObjectId.digest("blob", "too large")
      Dir.exists?(File.join(root, ".git", "objects", oid.byte_slice(0, 2))).should be_false
    end
  end

  it "P17-O03 refuses a symlinked fanout directory without touching its target" do
    GitOracle.with_repo do |root|
      content = "do not escape fanout\n"
      oid = Git::ObjectId.digest("blob", content)
      outside = File.join(File.dirname(root), "untrusted")
      Dir.mkdir_p(outside)
      marker = File.join(outside, "marker")
      File.write(marker, "safe")
      File.symlink(outside, File.join(root, ".git", "objects", oid.byte_slice(0, 2)))
      expect_raises(Git::Error, /directory/) { Git::Repository.new(root).write_blob(content) }
      File.read(marker).should eq("safe")
      Dir.children(outside).should eq(["marker"])
    end
  end

  it "P17-O04 refuses corrupt or symlinked existing object names without replacement" do
    GitOracle.with_repo do |root|
      content = "immutable object\n"
      oid = Git::ObjectId.digest("blob", content)
      folder = File.join(root, ".git", "objects", oid.byte_slice(0, 2))
      target = File.join(folder, oid.byte_slice(2, oid.bytesize - 2))
      Dir.mkdir(folder)
      File.write(target, "not zlib data")
      expect_raises(Git::Error) { Git::Repository.new(root).write_blob(content) }
      File.read(target).should eq("not zlib data")
      File.delete(target)
      other = File.join(File.dirname(root), "other-data")
      File.write(other, "outside")
      File.symlink(other, target)
      expect_raises(Git::Error, /regular file/) { Git::Repository.new(root).write_blob(content) }
      File.read(other).should eq("outside")
    end
  end

  it "P17-O06 exposes a standalone cancellation/checkpoint hook for native calls" do
    GitOracle.with_repo do |root|
      content = "host-cancelled blob\n"
      oid = Git::ObjectId.digest("blob", content)
      checks = 0
      callback = -> do
        checks += 1
        raise Git::Error.new("cancel before publication") if checks == 2
      end
      expect_raises(Git::Error, /cancel before publication/) do
        Git::Repository.new(root).write_blob(content, check: callback)
      end
      checks.should eq(2)
      folder = File.join(root, ".git", "objects", oid.byte_slice(0, 2))
      Dir.children(folder).should be_empty
      # A successful hook witnesses the prewrite, prepublish and completion
      # checkpoints without changing object contents or OID.
      checks = 0
      Git::Repository.new(root).write_blob(content, check: -> { checks += 1 }).should eq(oid)
      checks.should eq(3)
    end
  end

  it "P17-O05 cleans up temporary files if the caller aborts before publication" do
    GitOracle.with_repo do |root|
      content = "cancel before publication"
      oid = Git::ObjectId.digest("blob", content)
      db = Git::ObjectDatabase.new(File.join(root, ".git"), Git::ObjectId::Format::SHA1)
      calls = 0
      expect_raises(Git::Error, /cancelled/) do
        db.write_blob(content) do
          calls += 1
          raise Git::Error.new("cancelled") if calls == 2
        end
      end
      calls.should eq(2)
      folder = File.join(root, ".git", "objects", oid.byte_slice(0, 2))
      Dir.children(folder).should be_empty
    end
  end
end
