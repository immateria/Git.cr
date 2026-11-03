require "spec"
require "../src/git"
require "./support/git_oracle"

describe "native Git differential fixture infrastructure" do
  it "P01-O01 compares raw bytes and detects deliberately wrong expectations" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "binary.dat"), "blob\0bytes\n")
      oracle = GitOracle.run(root, "hash-object", "binary.dat").stdout
      GitOracle.assert_bytes!(oracle, GitOracle.run(root, "hash-object", "binary.dat").stdout, "P01-O01")
      expect_raises(GitOracle::Mismatch, /P01-O01/) do
        GitOracle.assert_bytes!(oracle, "0" * 40 + "\n", "P01-O01")
      end
      "\xff\0\n".to_slice.should eq(Bytes[0xff, 0, 10])
    end
  end

  it "P01-O02 independently checks detached HEAD, packed refs and tree content" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "blob.txt"), "one\n")
      GitOracle.run(root, "add", "blob.txt")
      GitOracle.run(root, "commit", "-qm", "first")
      GitOracle.run(root, "branch", "side")
      GitOracle.run(root, "tag", "start")
      GitOracle.run(root, "pack-refs", "--all", "--prune")
      git_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      store = Git::Repository.new(root)
      store.head[1].should eq(git_head)
      store.resolve_ref?("refs/heads/side").should eq(git_head)
      store.resolve_ref?("refs/tags/start").should eq(git_head)
      blob_oid = GitOracle.run(root, "rev-parse", "HEAD:blob.txt").stdout.strip
      store.read_head_file("blob.txt", 16 * 1024) { nil }.should eq({blob_oid, "one\n"})
      GitOracle.run(root, "checkout", "-q", "--detach", "HEAD")
      Git::Repository.new(root).head.should eq({nil, git_head})
    end
  end

  it "P01-O03 checks index stage bytes against Git's NUL-safe representation" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "a.txt"), "staged\n")
      GitOracle.run(root, "add", "a.txt")
      staged = GitOracle.run(root, "ls-files", "--stage", "-z").stdout
      oid = GitOracle.run(root, "hash-object", "a.txt").stdout.strip
      GitOracle.assert_bytes!(staged, "100644 #{oid} 0\ta.txt\0", "P01-O03")
      Git::Repository.new(root).staged_changes(32 * 1024, 4) { nil }[0].map(&.path).should eq(["a.txt"])
    end
  end

  it "P01-O04 checks ignore precedence and corrupted index refusal" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, ".gitignore"), "cache/\n!cache/file.txt\n")
      Dir.mkdir_p(File.join(root, "cache"))
      File.write(File.join(root, "cache", "file.txt"), "ignore\n")
      GitOracle.run(root, "check-ignore", "-q", "cache/file.txt")
      store = Git::Repository.new(root)
      changes, _, ignored = store.working_changes(32 * 1024, 30) { nil }
      changes.map(&.path).should_not contain("cache/file.txt")
      ignored.should be > 0
      File.write(File.join(root, "file.txt"), "staged\n")
      GitOracle.run(root, "add", "file.txt")
      raw = File.read(File.join(root, ".git", "index"))
      File.write(File.join(root, ".git", "index"), raw + "broken")
      expect_raises(Git::Error) { store.staged_changes(32 * 1024, 30) { nil } }
    end
  end

  it "P01-O05 resolves trusted linked worktree administration" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "base.txt"), "first\n")
      GitOracle.run(root, "add", "base.txt")
      GitOracle.run(root, "commit", "-qm", "first")
      linked = File.join(File.dirname(root), "linked")
      GitOracle.run(root, "worktree", "add", "-q", "-b", "linked", linked)
      pointer = File.read(File.join(linked, ".git")).strip
      admin = File.expand_path(pointer.sub("gitdir: ", ""), linked)
      Git::Repository.new(linked, linked_worktree_admin_dir: admin).head[1].should eq(
        GitOracle.run(linked, "rev-parse", "HEAD").stdout.strip)
      Git::Repository.new(linked).head[1].should eq(GitOracle.run(linked, "rev-parse", "HEAD").stdout.strip)
      expect_raises(Git::Error) { Git::Repository.new(linked, follow_gitfile: false) }
    end
  end
end

describe "SHA-256 Git object-format parity" do
  it "P03-O01 reads SHA-256 loose blob, tree, and commit exactly like Git" do
    GitOracle.with_repo(format: "sha256") do |root|
      File.write(File.join(root, "a.txt"), "sha256 content\n")
      GitOracle.run(root, "add", "a.txt")
      GitOracle.run(root, "commit", "-qm", "sha256 base")
      store = Git::Repository.new(root)
      head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      blob = GitOracle.run(root, "rev-parse", "HEAD:a.txt").stdout.strip
      store.head[1].should eq(head)
      store.commit(head, 128 * 1024) { nil }.subject.should eq("sha256 base")
      store.read_head_file("a.txt", 128 * 1024) { nil }.should eq({blob, "sha256 content\n"})
      store.staged_changes(128 * 1024, 20) { nil }[0].should be_empty
    end
  end

  it "P03-O02 reads SHA-256 packed objects, refs and staged/working OIDs" do
    GitOracle.with_repo(format: "sha256") do |root|
      File.write(File.join(root, "a.txt"), "before\n")
      GitOracle.run(root, "add", "a.txt")
      GitOracle.run(root, "commit", "-qm", "first")
      File.write(File.join(root, "a.txt"), "after\n")
      GitOracle.run(root, "add", "a.txt")
      GitOracle.run(root, "commit", "-qm", "second")
      GitOracle.run(root, "branch", "side")
      GitOracle.run(root, "pack-refs", "--all", "--prune")
      GitOracle.run(root, "gc", "--prune=now")
      store = Git::Repository.new(root)
      oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      store.commit(oid, 128 * 1024) { nil }.parents.size.should eq(1)
      store.resolve_ref?("refs/heads/side").should eq(oid)
      File.write(File.join(root, "a.txt"), "staged\n")
      GitOracle.run(root, "add", "a.txt")
      File.write(File.join(root, "a.txt"), "working\n")
      staged, _ = store.staged_changes(128 * 1024, 20) { nil }
      staged.map(&.path).should eq(["a.txt"])
      staged[0].index_oid.should eq(GitOracle.run(root, "rev-parse", ":a.txt").stdout.strip)
      working, _, _ = store.working_changes(128 * 1024, 20) { nil }
      working.find { |entry| entry.path == "a.txt" }.not_nil!.worktree_oid.should eq(
        GitOracle.run(root, "hash-object", "a.txt").stdout.strip)
    end
  end
end

describe "SHA-256 Git interoperability negatives and index variants" do
  it "P03-O03 reads version-2, 3 and 4 index formats with 32-byte IDs" do
    GitOracle.with_repo(format: "sha256") do |root|
      File.write(File.join(root, "one.txt"), "ONE\n")
      File.write(File.join(root, "two.txt"), "TWO\n")
      GitOracle.run(root, "add", "one.txt", "two.txt")
      GitOracle.run(root, "commit", "-qm", "initial")
      File.write(File.join(root, "one.txt"), "CHANGED\n")
      GitOracle.run(root, "add", "one.txt")
      [2, 3, 4].each do |version|
        # Git canonicalizes version 3 to 2 without extended flags. A real
        # skip-worktree entry requires v3, unlike a synthetic header edit.
        GitOracle.run(root, "update-index", "--skip-worktree", "two.txt") if version == 3
        GitOracle.run(root, "update-index", "--index-version", version.to_s)
        raw = File.read(File.join(root, ".git", "index"))
        raw.byte_slice(4, 4).to_slice.hexstring.should eq("%08x" % version)
        native = Git::Repository.new(root)
        native.object_format.should eq(Git::ObjectId::Format::SHA256)
        staged, truncated = native.staged_changes(128 * 1024, 10) { nil }
        truncated.should be_false
        staged.map(&.path).should eq(["one.txt"])
        staged[0].index_oid.should eq(GitOracle.run(root, "rev-parse", ":one.txt").stdout.strip)
        GitOracle.assert_bytes!(GitOracle.run(root, "ls-files", "--stage", "-z").stdout,
          "100644 #{GitOracle.run(root, "rev-parse", ":one.txt").stdout.strip} 0\tone.txt\0" +
          "100644 #{GitOracle.run(root, "rev-parse", ":two.txt").stdout.strip} 0\ttwo.txt\0", "P03-O03")
      end
    end
  end

  it "P03-O04 validates full SHA-256 object names, hashes raw bytes and rejects wrong-format IDs" do
    GitOracle.with_repo(format: "sha256") do |root|
      File.write(File.join(root, "blob.dat"), "sha256\0bytes\xff\n")
      expected = GitOracle.run(root, "hash-object", "blob.dat").stdout.strip
      Git::ObjectId.digest("blob", File.read(File.join(root, "blob.dat")), Git::ObjectId::Format::SHA256).should eq(expected)
      store = Git::Repository.new(root)
      store.object_format.should eq(Git::ObjectId::Format::SHA256)
      ["0" * 40, "a" * 63, "f" * 65, "F" * 64, "../" + "a" * 61].each do |bad|
        expect_raises(Git::Error, /unsupported Git OID/) { store.object(bad, 4096) { nil } }
      end
      expect_raises(Git::Error, /not available/) { store.object("0" * 64, 4096) { nil } }
    end
  end

  it "P03-O05 rejects SHA-256 pack index and pack corruption" do
    GitOracle.with_repo(format: "sha256") do |root|
      File.write(File.join(root, "blob.txt"), "packed sha256\n")
      GitOracle.run(root, "add", "blob.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      GitOracle.run(root, "gc", "--prune=now")
      oid = GitOracle.run(root, "rev-parse", "HEAD:blob.txt").stdout.strip
      store = Git::Repository.new(root)
      store.object(oid, 4096) { nil }[1].should eq("packed sha256\n")
      packdir = File.join(root, ".git", "objects", "pack")
      idx = Dir.glob(File.join(packdir, "*.idx")).first
      pack = idx.sub(/\.idx\z/, ".pack")
      # Git leaves both read-only, which only root writes through.
      File.chmod(idx, 0o644)
      File.chmod(pack, 0o644)
      index_contents = File.read(idx).to_slice.dup
      begin
        tampered = index_contents.dup
        tampered[tampered.size - 1] ^= 1
        File.write(idx, tampered)
        expect_raises(Git::Error, /checksum/) { store.object(oid, 4096) { nil } }
      ensure
        File.write(idx, index_contents)
      end
      pack_contents = File.read(pack).to_slice.dup
      begin
        tampered = pack_contents.dup
        tampered[tampered.size - 1] ^= 1
        File.write(pack, tampered)
        expect_raises(Git::Error, /checksum differs/) { store.object(oid, 4096) { nil } }
      ensure
        File.write(pack, pack_contents)
      end
    end
  end

  it "P03-O06 rejects invalid SHA-256 repo-format declarations and detects format drift" do
    GitOracle.with_repo(format: "sha256") do |root|
      store = Git::Repository.new(root)
      config = File.join(root, ".git", "config")
      original = File.read(config)
      begin
        File.write(config, original.sub(/repositoryformatversion = 1/i, "repositoryformatversion = 0"))
        expect_raises(Git::Error, /requires format version 1/) { Git::Repository.new(root) }
        File.write(config, original.sub(/objectformat = sha256/i, "objectformat = sha1"))
        expect_raises(Git::Error, /format changed/) { store.check! }
        File.write(config, original + "\n[extensions]\nrefStorage = reftable\n")
        expect_raises(Git::Error, /unsupported Git repository extension/) { Git::Repository.new(root) }
      ensure
        File.write(config, original)
      end
      store.check!
    end
  end
end

describe "SHA-256 Git REF_DELTA objects" do
  it "P03-O07 decodes Git-authored reference deltas with 32-byte base IDs" do
    GitOracle.with_repo(format: "sha256") do |root|
      # Large near-duplicate blobs reliably force a delta representation at
      # this bounded pack window/depth, instead of accidentally only testing
      # undeltified or OFS_DELTA objects.
      4.times do |variant|
        lines = Array(String).new(40) { "long shared paragraph ".ljust(100, 'a') }
        lines[10 + variant] = "UPDATED VARIANT # #{variant}" + variant.to_s * 50
        File.write(File.join(root, "a.txt"), lines.join("\n") + "\n")
        GitOracle.run(root, "add", "a.txt")
        GitOracle.run(root, "commit", "-qm", "revision #{variant}")
      end
      pack_prefix = File.join(root, ".git", "objects", "pack", "pack")
      pack_hash = GitOracle.run(root, "pack-objects", "--all", "--no-delta-base-offset", "--window=4",
        "--depth=4", pack_prefix, input: "").stdout.strip
      idx = "#{pack_prefix}-#{pack_hash}.idx"
      verify = GitOracle.run(root, "verify-pack", "-v", idx).stdout
      delta_ids = verify.lines.compact_map do |line|
        parts = line.split
        parts[0]? if parts.size == 7 && parts[1] == "blob" && parts[5] == "1"
      end
      delta_ids.size.should be > 0
      GitOracle.run(root, "prune-packed")
      native = Git::Repository.new(root)
      delta_ids.each do |oid|
        kind, data = native.object(oid, 128 * 1024) { nil }
        kind.should eq("blob")
        data.should eq(GitOracle.run(root, "cat-file", "blob", oid).stdout)
      end
    end
  end
end
