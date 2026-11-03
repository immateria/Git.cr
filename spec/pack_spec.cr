require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# A small history with renames, deletions, binary data and repeated
# content, so Git's repack produces OFS deltas.
private def pack_history(root : String, commits : Int32 = 12) : Nil
  commits.times do |i|
    File.write(File.join(root, "notes.txt"), (0..(40 + i)).map { |n| "line #{n} #{n % 7 == i % 7 ? "changed-#{i}" : "base"}\n" }.join)
    Dir.mkdir_p(File.join(root, "dir", "sub"))
    File.write(File.join(root, "dir", "sub", "deep-#{i % 3}.txt"), "deep #{i}\n" * (i + 1))
    File.write(File.join(root, "binary.bin"), String.new(Bytes.new(300 + i) { |b| ((b * 31 + i) % 256).to_u8 }))
    File.delete(File.join(root, "dir", "sub", "deep-#{(i + 1) % 3}.txt")) if i > 4 && File.exists?(File.join(root, "dir", "sub", "deep-#{(i + 1) % 3}.txt"))
    GitOracle.run(root, "add", "-A")
    GitOracle.run(root, "commit", "-qm", "commit #{i}", extra_env: {"GIT_COMMITTER_DATE" => "#{1_700_000_000 + i * 60} +0000", "GIT_AUTHOR_DATE" => "#{1_700_000_000 + i * 60} +0000"})
  end
  GitOracle.run(root, "tag", "-a", "v1", "-m", "release\n", "HEAD~3")
end

private def format_of(name : String) : Git::ObjectId::Format
  name == "sha256" ? Git::ObjectId::Format::SHA256 : Git::ObjectId::Format::SHA1
end

describe "Git::Pack" do
  ["sha1", "sha256"].each do |format|
    it "PACK-O01 indexes a Git-written delta pack to Git's exact .idx and .rev bytes (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        pack_history(root)
        GitOracle.run(root, "repack", "-adf", "--depth=50", "--window=50")
        GitOracle.run(root, "verify-pack", "-v", Dir.glob(File.join(root, ".git", "objects", "pack", "*.idx")).first).stdout.should contain("chain length")
        pack = Dir.glob(File.join(root, ".git", "objects", "pack", "*.pack")).first
        copy = File.join(File.dirname(root), "copy.pack")
        File.copy(pack, copy)
        result = Git::Pack.index_file(copy, format_of(format))
        stem = pack.byte_slice(0, pack.bytesize - 5)
        File.read(copy.sub(/\.pack\z/, ".idx")).to_slice.should eq(File.read(stem + ".idx").to_slice)
        File.read(copy.sub(/\.pack\z/, ".rev")).to_slice.should eq(File.read(stem + ".rev").to_slice)
        File.basename(stem).should eq("pack-#{result.checksum}")
        result.appended.should eq(0)
        listed = GitOracle.run(root, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)").stdout.lines.map(&.split)
        result.types.should eq(listed.to_h { |fields| {fields[0], fields[1]} })
      end
    end

    it "PACK-O02 writes packs that Git indexes identically and verifies (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        pack_history(root, 6)
        repo = Git::Repository.new(root)
        oids = GitOracle.run(root, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)").stdout.lines
        target = File.join(File.dirname(root), "native.pack")
        entries = [] of Git::Pack::IndexEntry
        checksum = File.open(target, "wb") do |io|
          writer = Git::Pack::Writer.new(io, format_of(format), oids.size)
          oids.each do |oid|
            stored = repo.read_object(oid, max_bytes: 1 << 20)
            kind, data = stored.type.to_s, stored.data
            offset, crc = writer.write_object(kind, data.to_slice)
            entries << Git::Pack::IndexEntry.new(oid, offset, crc)
          end
          writer.finish
        end
        GitOracle.run(File.dirname(root), "index-pack", "--object-format=#{format}", "-o", File.join(File.dirname(root), "git.idx"), target)
        idx = Git::Pack::IndexFile.encode(entries, checksum.hexbytes, format_of(format))
        idx.should eq(File.read(File.join(File.dirname(root), "git.idx")).to_slice)
        GitOracle.run(root, "verify-pack", target.sub(/\.pack\z/, ".idx").tap { |path| File.write(path, idx) })
      end
    end

    it "PACK-O03 receives a thin pack, appends its bases and leaves a valid repository (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        pack_history(root, 8)
        base = File.dirname(root)
        clone = File.join(base, "clone")
        GitOracle.run(base, "clone", "-q", "--no-local", "--bare", root, clone)
        # Advance the source so its new objects delta against old ones.
        File.write(File.join(root, "notes.txt"), File.read(File.join(root, "notes.txt")) + "appended\n")
        File.write(File.join(root, "binary.bin"), File.read(File.join(root, "binary.bin")) + "x")
        GitOracle.run(root, "commit", "-qam", "advance")
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        old = GitOracle.run(root, "rev-parse", "HEAD~1").stdout.strip
        thin = GitOracle.run(root, "pack-objects", "--thin", "--stdout", "--revs", input: "#{head}\n^#{old}\n").stdout
        File.write(File.join(base, "thin.pack"), thin)
        # Git itself refuses to index the thin pack without --fix-thin.
        GitOracle.run(base, "index-pack", "--object-format=#{format}", File.join(base, "thin.pack"), check: false).success?.should be_false

        repo = Git::Repository.new(clone)
        published = repo.index_pack(IO::Memory.new(thin))
        published.appended_bases.should be > 0
        published.object_count.should eq(published.entries.size)
        File.exists?(published.index_path.not_nil!).should be_true
        repo.refs.update("refs/heads/main", head, expected_oid: old)
        GitOracle.run(clone, "fsck", "--strict", "--no-dangling").success?.should be_true
        GitOracle.run(clone, "verify-pack", published.index_path.not_nil!).success?.should be_true
        GitOracle.run(clone, "cat-file", "-p", "#{head}:notes.txt").stdout.should end_with("appended\n")
        repo.read_object(head, max_bytes: 1 << 20).type.should eq(Git::ObjectType::Commit)

        # Receiving the same objects again publishes nothing new.
        again = repo.index_pack(IO::Memory.new(thin))
        again.pack_path.should eq(published.pack_path)
        Dir.glob(File.join(clone, "objects", "pack", "tmp_*")).should be_empty
      end
    end
  end

  it "PACK-O04 refuses corrupt, truncated and unresolvable packs without publishing" do
    GitOracle.with_repo do |root|
      pack_history(root, 4)
      head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      full = GitOracle.run(root, "pack-objects", "--stdout", "--revs", input: "#{head}\n").stdout.to_slice
      repo = Git::Repository.new(root)
      before = Dir.children(File.join(root, ".git", "objects", "pack")).sort

      truncated = full[0, full.size - 30]
      expect_raises(Git::Error) { repo.index_pack(IO::Memory.new(truncated)) }

      flipped = full.dup
      flipped[full.size // 2] ^= 0x55
      expect_raises(Git::Error) { repo.index_pack(IO::Memory.new(flipped)) }

      old = GitOracle.run(root, "rev-parse", "HEAD~1").stdout.strip
      thin = GitOracle.run(root, "pack-objects", "--thin", "--stdout", "--revs", input: "#{head}\n^#{old}\n").stdout
      empty = File.join(File.dirname(root), "empty")
      Dir.mkdir(empty)
      other = Git::Repository.init(empty, initial_branch: "main")
      expect_raises(Git::Error, /missing locally|unresolved/) { other.index_pack(IO::Memory.new(thin)) }
      expect_raises(Git::Error, /unresolved/) { other.index_pack(IO::Memory.new(thin), fix_thin: false) }
      Dir.children(File.join(empty, ".git", "objects", "pack")).should be_empty
      Dir.children(File.join(root, ".git", "objects", "pack")).sort.should eq(before)
    end
  end
end

describe "Git::Pack::Delta" do
  it "PACK-D01 round-trips encoded deltas through the pack reader's delta applier" do
    random = Random.new(42)
    sources = [
      Bytes.new(0),
      Bytes.new(15) { |i| i.to_u8 },
      Bytes.new(200_000) { random.rand(256).to_u8 },
      ("abcdefghijklmnop" * 9000).to_slice,
    ]
    sources.each do |source|
      targets = [
        source.dup,
        Bytes.new(0),
        Bytes.new(source.size // 2) { |i| source[i] },
        Bytes.new(source.size + 1000) { |i| i < 500 ? 7_u8 : (i - 500 < source.size ? source[i - 500] : 9_u8) },
        Bytes.new(source.size) { |i| i % 997 == 0 ? (source[i] ^ 0xff) : source[i] },
        Bytes.new(300_000) { |i| source.empty? ? 1_u8 : source[(i * 7) % source.size] },
      ]
      targets.each do |target|
        delta = Git::Pack::Delta.encode(source, target).not_nil!
        Git::Pack::Delta.apply(String.new(source), String.new(delta), Int64::MAX).to_slice.should eq(target)
      end
    end
    big = Bytes.new(100_000) { random.rand(256).to_u8 }
    edited = big.dup
    edited[50_000] ^= 1
    Git::Pack::Delta.encode(big, edited).not_nil!.size.should be < 64
    Git::Pack::Delta.encode(big, edited, max_size: 10).should be_nil
  end
end

describe "Git::Pack::Builder" do
  ["sha1", "sha256"].each do |format|
    it "PACK-O05 builds delta-compressed full and thin packs that Git accepts (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        pack_history(root, 14)
        repo = Git::Repository.new(root)
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        items = repo.reachable_objects([head])
        io = IO::Memory.new
        stats = Git::Pack::Builder.new(repo).write(io, items)
        stats.objects.should eq(items.size)
        stats.deltas.should be > 0
        stats.thin_deltas.should eq(0)
        undeltified = Git::Pack::Builder.new(repo, window: 0).write(IO::Memory.new, items)
        stats.bytes.should be < undeltified.bytes

        base = File.dirname(root)
        empty = File.join(base, "empty.git")
        GitOracle.run(base, "init", "-q", "--bare", "--object-format=#{format}", empty)
        GitOracle.run(empty, "index-pack", "--stdin", "--strict", input: io.to_s)
        GitOracle.run(empty, "update-ref", "refs/heads/main", head)
        GitOracle.run(empty, "fsck", "--strict", "--no-dangling")
        GitOracle.run(empty, "rev-list", "--objects", "--all").stdout.lines.size.should eq(items.size)

        # A thin pack of the last commit against its parent.
        parent = GitOracle.run(root, "rev-parse", "HEAD~1").stdout.strip
        new_items = repo.reachable_objects([head], [parent])
        old_items = repo.reachable_objects([parent])
        thin_io = IO::Memory.new
        thin = Git::Pack::Builder.new(repo).write(thin_io, new_items, old_items)
        thin.thin_deltas.should be > 0
        partial = File.join(base, "partial.git")
        GitOracle.run(base, "clone", "-q", "--bare", "--no-local", empty, partial)
        GitOracle.run(partial, "update-ref", "refs/heads/main", parent)
        GitOracle.run(partial, "repack", "-adq")
        GitOracle.run(partial, "prune", "--expire=now")
        GitOracle.run(partial, "index-pack", "--stdin", "--fix-thin", input: thin_io.to_s)
        GitOracle.run(partial, "update-ref", "refs/heads/main", head)
        GitOracle.run(partial, "fsck", "--strict", "--no-dangling")
      end
    end
  end
end

describe "Git object headers" do
  it "PACK-O06 reports type and size like git cat-file for loose, packed and deltified objects" do
    GitOracle.with_repo do |root|
      pack_history(root, 10)
      repo = Git::Repository.new(root)
      check = ->(label : String) do
        GitOracle.run(root, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)").stdout.lines.each do |line|
          oid, type, size = line.split
          {label, oid, repo.object_header(oid)}.should eq({label, oid, Git::ObjectHeader.new(Git::ObjectType.parse(type), size.to_i64)})
        end
      end
      check.call("loose")
      GitOracle.run(root, "repack", "-adf", "--depth=20", "--window=20")
      check.call("packed")
    end
  end
end
