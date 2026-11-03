require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def git_fixture_git(root : String, *args : String) : String
  result = IO::Memory.new
  errors = IO::Memory.new
  status = Process.run(GitOracle::GIT_BINARY, ["-C", root] + args.to_a, output: result, error: errors)
  raise "Git fixture operation failed #{args}: #{errors.to_s}" unless status.success?
  result.to_s.strip
end

private def git_fixture(&block : String ->)
  root = File.tempname("standalone-git", dir: File.realpath(Dir.tempdir))
  Dir.mkdir_p(root)
  begin
    git_fixture_git(root, "init", "-q")
    git_fixture_git(root, "config", "user.name", "Native Test")
    git_fixture_git(root, "config", "user.email", "native@example.invalid")
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "independent git shard" do
  it "loads from a direct require without a host, reads HEAD and staged status" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "before\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      File.write(File.join(root, "file.txt"), "after\n")
      git_fixture_git(root, "add", "file.txt")
      File.write(File.join(root, "file.txt"), "not staged\n")
      store = Git::Repository.new(root)
      store.head.oid.should eq(git_fixture_git(root, "rev-parse", "HEAD"))
      stage = store.staged_changes(max_bytes: 128 * 1024, limit: 20)
      truncated = stage.truncated?
      truncated.should be_false
      stage.map(&.path).should eq(["file.txt"])
      file = store.staged_file("file.txt", max_bytes: 128 * 1024).not_nil!
      file.old_text.should eq("before\n")
      file.new_text.should eq("after\n")
      working = store.working_changes(max_bytes: 128 * 1024, limit: 20)
      working.map(&.status).should contain("modified")
    end
  end

  it "matches ordinary Git ignored/untracked files, including local and nested excludes" do
    git_fixture do |root|
      File.write(File.join(root, "main.cr"), "base\n")
      git_fixture_git(root, "add", "main.cr")
      git_fixture_git(root, "commit", "-qm", "base")
      File.write(File.join(root, ".gitignore"), "*.log\ncache/\n")
      Dir.mkdir_p(File.join(root, "cache"))
      File.write(File.join(root, "cache", "ignore.txt"), "in cache\n")
      Dir.mkdir_p(File.join(root, "nested"))
      File.write(File.join(root, "nested", ".gitignore"), "*.bak\n!keep.bak\n")
      File.write(File.join(root, "nested", "junk.bak"), "ignore\n")
      File.write(File.join(root, "nested", "keep.bak"), "keep\n")
      File.write(File.join(root, "hello.log"), "ignore\n")
      File.write(File.join(root, "new.txt"), "new\n")
      File.write(File.join(root, ".git", "info", "exclude"), "excluded.tmp\n")
      File.write(File.join(root, "excluded.tmp"), "ignore\n")
      changes = Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 60)
      ignored = changes.ignored
      unknown = changes.select(&.status.==("untracked")).map(&.path).sort
      unknown.should eq([".gitignore", "nested/.gitignore", "nested/keep.bak", "new.txt"])
      ignored.should be >= 3
      # Git's untracked-file oracle includes same four visible paths.
      git_fixture_git(root, "ls-files", "--others", "--exclude-standard").lines.map(&.strip).sort.should eq(unknown)
    end
  end

  it "generates a reversible staged unified patch without reading the working copy" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "a\nb\nc\nd\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      File.write(File.join(root, "file.txt"), "a\nB\nc\nd\ne\n")
      git_fixture_git(root, "add", "file.txt")
      File.write(File.join(root, "file.txt"), "unstaged only\n")
      store = Git::Repository.new(root)
      file = store.staged_file("file.txt", max_bytes: 128 * 1024).not_nil!
      patch = Git::TextDiff.unified(file.old_text, file.new_text, file.path, file.old_mode, file.new_mode)
      patch.should contain("+B")
      patch.should_not contain("unstaged only")
      path = File.join(root, "test.patch")
      File.write(path, patch)
      git_fixture_git(root, "apply", "--check", "--reverse", "--cached", path)
    end
  end

  it "fails closed on malformed metadata and excessive diff complexity" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "one\n")
      git_fixture_git(root, "add", "file.txt")
      original = File.read(File.join(root, ".git", "index"))
      File.write(File.join(root, ".git", "index"), original + "garbage")
      expect_raises(Git::Error) { Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 3) }
    end
    a = (1..600).map { |i| "old #{i}\n" }.join
    b = (1..600).map { |i| "new #{i}\n" }.join
    expect_raises(Git::Error) { Git::TextDiff.unified(a, b, "file.txt", "100644", "100644") }
  end
end

describe "native Git staging patch edge cases" do
  it "emits a reversible no-newline patch for an added file" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "base\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      File.write(File.join(root, "new.txt"), "without newline")
      git_fixture_git(root, "add", "new.txt")
      staged = Git::Repository.new(root).staged_file("new.txt", max_bytes: 128 * 1024).not_nil!
      patch = Git::TextDiff.unified(staged.old_text, staged.new_text, staged.path, staged.old_mode, staged.new_mode)
      patch.should contain("No newline at end of file")
      File.write(File.join(root, "patch.bin"), patch)
      git_fixture_git(root, "apply", "--check", "--reverse", "--cached", File.join(root, "patch.bin"))
    end
  end

  it "handles staged deletions and non-overlapping hunks as reversible patches" do
    git_fixture do |root|
      original = (1..40).map { |i| "line #{i}\n" }.join
      File.write(File.join(root, "file.txt"), original)
      File.write(File.join(root, "deleted.txt"), "remove this\n")
      git_fixture_git(root, "add", "-A")
      git_fixture_git(root, "commit", "-qm", "base")
      changed = original.sub("line 2\n", "line 2 changed\n").sub("line 38\n", "line 38 changed\n")
      File.write(File.join(root, "file.txt"), changed)
      File.delete(File.join(root, "deleted.txt"))
      git_fixture_git(root, "add", "-A")
      store = Git::Repository.new(root)
      ["file.txt", "deleted.txt"].each do |path|
        staged = store.staged_file(path, max_bytes: 128 * 1024).not_nil!
        patch = Git::TextDiff.unified(staged.old_text, staged.new_text, path, staged.old_mode, staged.new_mode)
        patch.includes?("@@").should be_true
        File.write(File.join(root, "patch.bin"), patch)
        git_fixture_git(root, "apply", "--check", "--reverse", "--cached", File.join(root, "patch.bin"))
      end
    end
  end

  it "does not follow symbolic directories while looking for untracked files" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "base\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      outside = File.tempname("git-outside", dir: File.realpath(Dir.tempdir))
      Dir.mkdir_p(outside)
      begin
        File.write(File.join(outside, "secret.txt"), "protected\n")
        File.symlink(outside, File.join(root, "alias"))
        changes = Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 10)
        changes.map(&.path).should contain("alias")
        changes.map(&.path).should_not contain("alias/secret.txt")
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end
end

describe "Git text patch path encoding" do
  it "quotes unusual filenames without permitting unsafe path components" do
    ["space name", "quote\"name", "back\\slash", "line\nfeed", "caf\u00e9", String.new(Bytes[0xff])].each do |name|
      patch = Git::TextDiff.unified("before\n", "after\n", name, "100644", "100644")
      patch.should contain("diff --git ")
      patch.should contain("@@ ")
    end
    ["bad\0name", "../escape", "/absolute", "a//b", ".git/secrets"].each do |name|
      expect_raises(ArgumentError) { Git::TextDiff.unified("before\n", "after\n", name, "100644", "100644") }
    end
    Git::TextDiff.unified("before\n", "after\n", "src/valid-file.cr", "100644", "100644").should contain("diff --git a/src/valid-file.cr")
  end
end

describe "Git working-tree scope checks" do
  it "refuses a symlinked tracked parent before reading a tracked symlink" do
    git_fixture do |root|
      Dir.mkdir_p(File.join(root, "safe"))
      File.symlink("local-target", File.join(root, "safe", "link"))
      git_fixture_git(root, "add", "safe/link")
      git_fixture_git(root, "commit", "-qm", "tracked symlink")
      outside = File.tempname("git-external-symlink-parent", dir: File.realpath(Dir.tempdir))
      Dir.mkdir_p(outside)
      begin
        File.symlink("different-external-target", File.join(outside, "link"))
        File.rename(File.join(root, "safe"), File.join(root, "former-safe"))
        File.symlink(outside, File.join(root, "safe"))
        expect_raises(Git::Error) do
          Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 20, include_untracked: false)
        end
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end
end

describe "Git working-tree unified diff" do
  it "compares staged index bytes with working file and emits a reversible patch" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "head\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "baseline")
      File.write(File.join(root, "file.txt"), "staged\n")
      git_fixture_git(root, "add", "file.txt")
      File.write(File.join(root, "file.txt"), "working\n")
      file = Git::Repository.new(root).working_file("file.txt", max_bytes: 128 * 1024).not_nil!
      file.old_text.should eq("staged\n")
      file.new_text.should eq("working\n")
      patch = Git::TextDiff.unified(file.old_text, file.new_text, file.path, file.old_mode, file.new_mode)
      patch.should contain("-staged")
      patch.should contain("+working")
      patch.should_not contain("-head")
      File.write(File.join(root, "work.patch"), patch)
      git_fixture_git(root, "apply", "--check", "--reverse", "work.patch")
    end
  end

  it "handles unchanged and deleted tracked files" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "unchanged\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "baseline")
      store = Git::Repository.new(root)
      store.working_file("file.txt", max_bytes: 128 * 1024).should be_nil
      File.delete(File.join(root, "file.txt"))
      deleted = store.working_file("file.txt", max_bytes: 128 * 1024).not_nil!
      deleted.new_mode.should be_nil
      Git::TextDiff.unified(deleted.old_text, deleted.new_text, deleted.path, deleted.old_mode, deleted.new_mode).should contain("-unchanged")
    end
  end

  it "emits a reversible mode-only diff" do
    git_fixture do |root|
      target = File.join(root, "file.txt")
      File.write(target, "same\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      File.chmod(target, 0o755)
      work = Git::Repository.new(root).working_file("file.txt", max_bytes: 128 * 1024).not_nil!
      work.new_mode.should eq("100755")
      patch = Git::TextDiff.unified(work.old_text, work.new_text, work.path, work.old_mode, work.new_mode)
      patch.should contain("new mode 100755")
      File.write(File.join(root, "mode.patch"), patch)
      git_fixture_git(root, "apply", "--check", "--reverse", "mode.patch")
    end
  end

  it "refuses symbolic-link redirection and binary text" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "text\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "baseline")
      outside = File.tempname("git-diff-outside", dir: File.realpath(Dir.tempdir))
      File.write(outside, "outside\n")
      begin
        File.delete(File.join(root, "file.txt"))
        File.symlink(outside, File.join(root, "file.txt"))
        expect_raises(Git::Error) { Git::Repository.new(root).working_file("file.txt", max_bytes: 128 * 1024) }
        File.delete(File.join(root, "file.txt"))
        File.write(File.join(root, "file.txt"), "binary\0content")
        expect_raises(Git::Error) { Git::Repository.new(root).working_file("file.txt", max_bytes: 128 * 1024) }
      ensure
        File.delete(outside) if File.exists?(outside)
      end
    end
  end
end

describe "Git storage component boundaries" do
  it "validates raw object IDs before accessing the loose or packed stores" do
    git_fixture do |root|
      store = Git::Repository.new(root)
      ["../../escape", "F" * 40, "a" * 39, "../" + "b" * 37].each do |bad|
        expect_raises(Git::Error, /unsupported Git OID/) { store.read_object(bad, max_bytes: 4096) }
      end
      File.write(File.join(root, "probe.txt"), "content\n")
      Git::ObjectId.digest("blob", "content\n").should eq(git_fixture_git(root, "hash-object", "probe.txt"))
    end
  end

  it "resolves packed branch and tag references and reads committed tree paths" do
    git_fixture do |root|
      Dir.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "code.cr"), "puts 123\n")
      git_fixture_git(root, "add", "src/code.cr")
      git_fixture_git(root, "commit", "-qm", "base")
      git_fixture_git(root, "branch", "topic")
      git_fixture_git(root, "tag", "v1")
      git_fixture_git(root, "pack-refs", "--all", "--prune")
      store = Git::Repository.new(root)
      head = git_fixture_git(root, "rev-parse", "HEAD")
      store.refs.resolve?("refs/heads/topic").should eq(head)
      store.refs.resolve?("refs/tags/v1").should eq(head)
      store.refs.list.map(&.name).should contain("refs/tags/v1")
      store.read_commit(head, max_bytes: 128 * 1024).subject.should eq("base")
      store.head_directory("src", max_bytes: 128 * 1024).map(&.name).should eq(["code.cr"])
      store.read_head_file("src/code.cr", max_bytes: 128 * 1024).should eq("puts 123\n")
    end
  end

  it "reconstructs real packed blob deltas after repacking" do
    git_fixture do |root|
      versions = [] of String
      7.times do |i|
        text = (1..350).map { |n| "row #{n}: #{"A" * 24} #{n == 23 + i ? "version-#{i}" : "base"}\n" }.join
        versions << text
        File.write(File.join(root, "payload.txt"), text)
        git_fixture_git(root, "add", "payload.txt")
        git_fixture_git(root, "commit", "-qm", "revision-#{i}")
      end
      git_fixture_git(root, "repack", "-adf", "--depth=50", "--window=50")
      idx = Dir.glob(File.join(root, ".git", "objects", "pack", "*.idx")).first
      pack_listing = git_fixture_git(root, "verify-pack", "-v", idx)
      pack_listing.lines.any? { |line| line.split.size >= 7 && line.includes?("blob") }.should be_true
      store = Git::Repository.new(root)
      versions.each_with_index do |text, i|
        oid = git_fixture_git(root, "rev-parse", "HEAD~#{6 - i}:payload.txt")
        stored = store.read_object(oid, max_bytes: 128 * 1024)
        kind, contents = stored.type.to_s, stored.data
        kind.should eq("blob")
        contents.should eq(text)
      end
    end
  end
end

describe "Git packed storage with deep delta chains" do
  it "reads objects at the end of a Git-written chain deeper than 50" do
    git_fixture do |root|
      versions = [] of String
      120.times do |i|
        text = (1..200).map { |n| "row #{n}: #{n <= i ? "edited-#{n}" : "base"}\n" }.join
        versions << text
        File.write(File.join(root, "payload.txt"), text)
        git_fixture_git(root, "add", "payload.txt")
        git_fixture_git(root, "commit", "-qm", "revision-#{i}")
      end
      git_fixture_git(root, "repack", "-adf", "--depth=200", "--window=250")
      idx = Dir.glob(File.join(root, ".git", "objects", "pack", "*.idx")).first
      depths = git_fixture_git(root, "verify-pack", "-v", idx).lines.compact_map do |line|
        fields = line.split
        fields.size == 7 && fields[1] == "blob" ? fields[5].to_i : nil
      end
      depths.max.should be > 50
      store = Git::Repository.new(root)
      versions.each_with_index do |text, i|
        oid = git_fixture_git(root, "rev-parse", "HEAD~#{119 - i}:payload.txt")
        store.read_object(oid, max_bytes: 128 * 1024).should eq(Git::RawObject.new(Git::ObjectType::Blob, text))
      end
      history = store.history(limit: 200, max_nodes: 200)
      history.commits.size.should eq(120)
    end
  end
end

describe "Git linked-worktree metadata component" do
  it "requires an explicitly selected admin path and resolves the linked HEAD" do
    git_fixture do |root|
      File.write(File.join(root, "file.txt"), "committed\n")
      git_fixture_git(root, "add", "file.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      linked = File.tempname("git-metadata-worktree", dir: File.realpath(Dir.tempdir))
      begin
        git_fixture_git(root, "worktree", "add", "-qb", "review", linked)
        Git::Repository.new(linked).head.symref_target.should eq("refs/heads/review")
        expect_raises(Git::Error) { Git::Repository.new(linked, follow_gitfile: false) }
        admin = File.join(root, ".git", "worktrees", File.basename(linked))
        store = Git::Repository.new(linked, linked_worktree_admin_dir: admin)
        store.head.symref_target.should eq("refs/heads/review")
        store.head.oid.should eq(git_fixture_git(root, "rev-parse", "HEAD"))
        store.read_head_file("file.txt", max_bytes: 128 * 1024).should eq("committed\n")
        store.revalidate!
      ensure
        git_fixture_git(root, "worktree", "remove", "--force", linked) if Dir.exists?(linked)
      end
    end
  end
end

describe "Git ignore wildcard compatibility" do
  it "matches Git's boundary-sensitive star runs and escaped trailing spaces" do
    git_fixture do |root|
      Dir.mkdir_p(File.join(root, "dir"))
      cases = [
        {"a/**b", ["a/b", "a/xxb", "a/x/b", "a/x/y/b"]},
        {"a/**/b", ["a/b", "a/x/b", "a/x/y/b", "a/x/b/child"]},
        {"a/***/b", ["a/b", "a/x/b", "a/x/y/b", "a/x/b/child"]},
        {"a/**", ["a/x", "a/x/y", "a"]},
        {"a/*/b", ["a/b", "a/x/b", "a/x/y/b"]},
        {"dir/\n!dir/keep", ["dir", "dir/keep", "dir/other"]},
        {"dir/\n!dir/\n!dir/keep", ["dir", "dir/keep", "dir/other"]},
        {"a/**/b\n!a/x/b/child", ["a/x/b/child", "a/x/b", "a/b"]},
        {"literal\\\\ ", ["literal\\", "literal\\ ", "literal "]},
        {"literal\\ ", ["literal ", "literal\\"]},
      ]
      cases.each do |pattern, paths|
        File.write(File.join(root, ".gitignore"), "#{pattern}\n")
        matcher = Git::Ignore.new(root, File.join(root, ".git"), 128 * 1024)
        paths.each do |path|
          result = Process.run(GitOracle::GIT_BINARY, ["-C", root, "check-ignore", "-q", "--", path])
          raise "Git oracle failed" unless {0, 1}.includes?(result.exit_code)
          matcher.ignored?(path, path == "dir").should eq(result.success?), "pattern=#{pattern.inspect} path=#{path.inspect}"
        end
      end
    end
  end

  it "reports nested paths that Git leaves unignored, even if the pattern contains double stars" do
    git_fixture do |root|
      File.write(File.join(root, "tracked.txt"), "base\n")
      git_fixture_git(root, "add", "tracked.txt")
      git_fixture_git(root, "commit", "-qm", "base")
      File.write(File.join(root, ".gitignore"), "logs/**old.log\n")
      Dir.mkdir_p(File.join(root, "logs", "deep"))
      File.write(File.join(root, "logs", "deep", "old.log"), "visible\n")
      File.write(File.join(root, "logs", "xxold.log"), "ignored\n")
      actual = Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 20)
      visible = actual.select(&.status.==("untracked")).map(&.path).sort
      expected = git_fixture_git(root, "ls-files", "--others", "--exclude-standard").lines.map(&.strip).sort
      visible.should eq(expected)
    end
  end
end

private def git_pack_fixture(root : String) : {String, String, String}
  File.write(File.join(root, "packed.txt"), "packed Git fixture\n")
  git_fixture_git(root, "add", "packed.txt")
  git_fixture_git(root, "commit", "-qm", "packed fixture")
  oid = git_fixture_git(root, "rev-parse", "HEAD:packed.txt")
  git_fixture_git(root, "repack", "-adf")
  git_fixture_git(root, "prune-packed")
  idx = Dir.glob(File.join(root, ".git", "objects", "pack", "*.idx")).first
  {oid, idx, idx.sub(/\.idx\z/, ".pack")}
end

private def git_fixture_rechecksum!(bytes : Bytes) : Nil
  actual = Digest::SHA1.hexdigest(bytes[0, bytes.size - 20]).hexbytes
  20.times { |i| bytes[bytes.size - 20 + i] = actual[i] }
end

private def git_fixture_write_bytes(file : String, bytes : Bytes) : Nil
  # Git leaves packs and their indexes read-only, which only root writes
  # through; the fixture's owner may make them writable first.
  File.chmod(file, 0o644)
  File.open(file, "wb") { |io| io.write(bytes) }
end

private def git_fixture_uint32!(bytes : Bytes, pos : Int32, value : UInt32) : Nil
  bytes[pos] = (value >> 24).to_u8
  bytes[pos + 1] = ((value >> 16) & 0xff).to_u8
  bytes[pos + 2] = ((value >> 8) & 0xff).to_u8
  bytes[pos + 3] = (value & 0xff).to_u8
end

describe "Git packed storage corruption boundaries" do
  it "rejects a corrupt index digest and a recomputed, nonmonotonic fanout" do
    git_fixture do |root|
      oid, idx, _ = git_pack_fixture(root)
      original = File.read(idx).to_slice.dup
      corrupt = original.dup
      corrupt[corrupt.size - 1] ^= 1
      git_fixture_write_bytes(idx, corrupt)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }

      bad_fanout = original.dup
      # No valid index can have more objects in bucket 0 than in bucket 1.
      git_fixture_uint32!(bad_fanout, 8, 0xffff_ffff_u32)
      git_fixture_rechecksum!(bad_fanout)
      git_fixture_write_bytes(idx, bad_fanout)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects invalid large-offset table references even with a valid index checksum" do
    git_fixture do |root|
      oid, idx, _ = git_pack_fixture(root)
      bytes = File.read(idx).to_slice.dup
      count = (0...4).reduce(0_u32) { |n, i| (n << 8) | bytes[8 + 255 * 4 + i].to_u32 }.to_i
      oid_rows = 8 + 1024
      row = (0...count).find { |i| bytes[oid_rows + i * 20, 20].hexstring == oid }.not_nil!
      offset_table = oid_rows + count * 24
      git_fixture_uint32!(bytes, offset_table + row * 4, 0x8000_0000_u32)
      git_fixture_rechecksum!(bytes)
      git_fixture_write_bytes(idx, bytes)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects a forged pack-index pairing and mismatched object counts" do
    git_fixture do |root|
      oid, _, pack = git_pack_fixture(root)
      original = File.read(pack).to_slice.dup
      changed_trailer = original.dup
      changed_trailer[changed_trailer.size - 1] ^= 1
      git_fixture_write_bytes(pack, changed_trailer)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }

      bad_count = original.dup
      git_fixture_uint32!(bad_count, 8, 1_000_u32)
      git_fixture_write_bytes(pack, bad_count)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects a forged packed-object CRC even when the index digest is updated" do
    git_fixture do |root|
      oid, idx, _ = git_pack_fixture(root)
      bytes = File.read(idx).to_slice.dup
      count = (0...4).reduce(0_u32) { |n, i| (n << 8) | bytes[8 + 255 * 4 + i].to_u32 }.to_i
      oid_rows = 8 + 1024
      row = (0...count).find { |i| bytes[oid_rows + i * 20, 20].hexstring == oid }.not_nil!
      crc_table = oid_rows + count * 20
      bytes[crc_table + row * 4] ^= 1
      git_fixture_rechecksum!(bytes)
      git_fixture_write_bytes(idx, bytes)
      expect_raises(Git::Error, /CRC/) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects an index with invalid table widths but a valid SHA-1 checksum" do
    git_fixture do |root|
      oid, idx, _ = git_pack_fixture(root)
      bytes = File.read(idx).to_slice.dup
      forged = Bytes.new(bytes.size + 1)
      forged[0, bytes.size - 40].copy_from(bytes[0, bytes.size - 40])
      forged[bytes.size - 39, 40].copy_from(bytes[bytes.size - 40, 40])
      git_fixture_rechecksum!(forged)
      git_fixture_write_bytes(idx, forged)
      expect_raises(Git::Error) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects damaged compressed entry bytes before decompression" do
    git_fixture do |root|
      oid, idx, pack = git_pack_fixture(root)
      table = File.read(idx).to_slice
      count = (0...4).reduce(0_u32) { |n, i| (n << 8) | table[8 + 255 * 4 + i].to_u32 }.to_i
      oid_rows = 8 + 1024
      row = (0...count).find { |i| table[oid_rows + i * 20, 20].hexstring == oid }.not_nil!
      pos = oid_rows + count * 24 + row * 4
      entry_offset = (0...4).reduce(0_u32) { |n, i| (n << 8) | table[pos + i].to_u32 }.to_i
      bytes = File.read(pack).to_slice.dup
      bytes[entry_offset + 2] ^= 1
      git_fixture_write_bytes(pack, bytes)
      expect_raises(Git::Error, /CRC/) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "reads bounded large-offset index entries and rejects UInt64 overflow" do
    git_fixture do |root|
      oid, idx, _ = git_pack_fixture(root)
      original = File.read(idx).to_slice.dup
      count = (0...4).reduce(0_u32) { |n, i| (n << 8) | original[8 + 255 * 4 + i].to_u32 }.to_i
      oid_rows = 8 + 1024
      row = (0...count).find { |i| original[oid_rows + i * 20, 20].hexstring == oid }.not_nil!
      pos = oid_rows + count * 24 + row * 4
      offset = (0...4).reduce(0_u32) { |n, i| (n << 8) | original[pos + i].to_u32 }.to_u64
      forged = Bytes.new(original.size + 8)
      body_end = original.size - 40
      forged[0, body_end].copy_from(original[0, body_end])
      forged[body_end + 8, 40].copy_from(original[body_end, 40])
      8.times { |i| forged[body_end + i] = ((offset >> ((7 - i) * 8)) & 0xff).to_u8 }
      git_fixture_uint32!(forged, pos, 0x8000_0000_u32)
      git_fixture_rechecksum!(forged)
      git_fixture_write_bytes(idx, forged)
      Git::Repository.new(root).read_object(oid, max_bytes: 4096).data.should eq("packed Git fixture\n")

      8.times { |i| forged[body_end + i] = 0xff_u8 }
      git_fixture_rechecksum!(forged)
      git_fixture_write_bytes(idx, forged)
      expect_raises(Git::Error, /large offset/) { Git::Repository.new(root).read_object(oid, max_bytes: 4096) }
    end
  end

  it "rejects an over-deep offset delta chain with bounded reconstruction" do
    git_fixture do |root|
      pack = File.join(root, "deep-chain.pack")
      last = 12_i64
      File.open(pack, "wb") do |io|
        io.write("PACK".to_slice)
        io.write_bytes(2_u32, IO::ByteFormat::BigEndian)
        io.write_bytes(27_u32, IO::ByteFormat::BigEndian)
        io.write_byte(0x30_u8) # undeltified empty blob
        Compress::Zlib::Writer.open(io) { |z| z.write(Bytes.empty) }
        26.times do
          offset = io.pos
          distance = offset - last
          raise "fixture delta distance unexpectedly large" unless (1...128).includes?(distance)
          io.write_byte(0x62_u8) # OFS_DELTA, two inflated instruction bytes
          io.write_byte(distance.to_u8)
          Compress::Zlib::Writer.open(io) { |z| z.write(Bytes[0, 0]) }
          last = offset
        end
        io.write(Bytes.new(20))
      end
      resolver = ->(_oid : String, _depth : Int32, _seen : Set(String)) { {"blob", ""} }
      expect_raises(Git::Error, /delta chain too deep/) do
        Git::ObjectDatabase::PackFiles.new(root, Git::ObjectId::Format::SHA1, max_delta_depth: 24).decode_pack(pack, last, 1024, 0, Set(String).new, resolver) { nil }
      end
      # The default budget follows Git, whose packs carry chains of up to 4095.
      Git::ObjectDatabase::PackFiles.new(root, Git::ObjectId::Format::SHA1).decode_pack(pack, last, 1024, 0, Set(String).new, resolver) { nil }.should eq({"blob", ""})
    end
  end

  it "rejects an oversized OFS_DELTA distance encoding without integer overflow" do
    git_fixture do |root|
      pack = File.join(root, "bad-distance.pack")
      File.open(pack, "wb") do |io|
        io.write("PACK".to_slice)
        io.write_bytes(2_u32, IO::ByteFormat::BigEndian)
        io.write_bytes(1_u32, IO::ByteFormat::BigEndian)
        io.write_byte(0x60_u8)
        32.times { io.write_byte(0xff_u8) }
        io.write_byte(0x00_u8)
        io.write(Bytes.new(20))
      end
      resolver = ->(_oid : String, _depth : Int32, _seen : Set(String)) { {"blob", ""} }
      expect_raises(Git::Error) do
        Git::ObjectDatabase::PackFiles.new(root, Git::ObjectId::Format::SHA1).decode_pack(pack, 12_i64, 1024, 0, Set(String).new, resolver) { nil }
      end
    end
  end
end
