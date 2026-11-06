require "spec"
require "json"
require "../src/git"
require "./support/git_oracle"

describe "Git raw pathname compatibility" do
  it "P04-O01 retains exact index/tree bytes for unusual names, including invalid UTF-8" do
    ["sha1", "sha256"].each do |format|
      GitOracle.with_repo(format: format) do |root|
        names = ["has space.txt", "tab\tname", "line\nname", "slash\\name", "quote\"name", "caf\u00e9.txt", String.new(Bytes[0xff, 0x6e, 0x61, 0x6d, 0x65])]
        names.each_with_index do |name, i|
          File.write(File.join(root, name), "content #{i}\n") if GitOracle.storable?(name)
        end
        GitOracle.run(root, "add", "--all")
        names.each_with_index do |name, i|
          GitOracle.stage_blob(root, name, "content #{i}\n") unless GitOracle.storable?(name)
        end
        index_output = GitOracle.run(root, "ls-files", "--stage", "-z").stdout
        names.each do |name|
          index_output.includes?(name).should be_true
        end
        store = Git::Repository.new(root)
        staged = store.staged_changes(max_bytes: 128 * 1024, limit: 20)
        truncated = staged.truncated?
        truncated.should be_false
        staged.size.should eq(names.size)
        names.each do |name|
          staged.any? { |entry| entry.path.to_slice == name.to_slice }.should be_true
        end
        GitOracle.run(root, "commit", "-qm", "add unusual names")
        tree_output = GitOracle.run(root, "ls-tree", "-z", "HEAD").stdout
        tree = Git::Repository.new(root).head_directory(".", max_bytes: 128 * 1024)
        names.each do |name|
          tree.any? { |entry| entry.name.to_slice == name.to_slice }.should be_true
          tree_output.includes?(name).should be_true
          Git::Repository.new(root).read_head_file(name, max_bytes: 128 * 1024).should start_with("content")
        end
      end
    end
  end

  it "P04-O02 retains non-UTF-8 index v4 prefix-compressed names and modified worktree bytes" do
    GitOracle.with_repo do |root|
      first = String.new(Bytes[0xff, 0x70, 0x72, 0x65, 0x66, 0x69, 0x78, 0x2d, 0x61])
      second = String.new(Bytes[0xff, 0x70, 0x72, 0x65, 0x66, 0x69, 0x78, 0x2d, 0x62])
      if GitOracle::RAW_NAMES
        File.write(File.join(root, first), "first\n")
        File.write(File.join(root, second), "second\n")
        GitOracle.run(root, "add", "--all")
      else
        GitOracle.stage_blob(root, first, "first\n")
        GitOracle.stage_blob(root, second, "second\n")
      end
      GitOracle.run(root, "commit", "-qm", "v4 unusual")
      GitOracle.run(root, "update-index", "--index-version", "4")
      # A modified work-tree file under such a name exists only where the
      # file system takes the name.
      if GitOracle::RAW_NAMES
        File.write(File.join(root, second), "changed\n")
        changes = Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 20, include_untracked: false)
        truncated = changes.truncated?
        truncated.should be_false
        changes.size.should eq(1)
        changes.first.path.to_slice.should eq(second.to_slice)
        changes.first.worktree_oid.should eq(GitOracle.run(root, "hash-object", second).stdout.strip)
        File.write(File.join(root, first), "staged\n")
        GitOracle.run(root, "add", "--", first)
      else
        GitOracle.stage_blob(root, first, "staged\n")
      end
      File.open(File.join(root, ".git", "index")) do |io|
        io.skip(4)
        io.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(4)
      end
      staged = Git::Repository.new(root).staged_changes(max_bytes: 128 * 1024, limit: 20)
      staged.map(&.path).should eq([first])
      GitOracle.assert_bytes!(GitOracle.run(root, "ls-files", "--stage", "-z").stdout,
        "100644 #{GitOracle.run(root, "rev-parse", ":#{first}").stdout.strip} 0\t#{first}\0" +
        "100644 #{GitOracle.run(root, "rev-parse", ":#{second}").stdout.strip} 0\t#{second}\0", "P04-O02")
    end
  end
end

describe "Git reference-name and text-patch byte parity" do
  it "P04-O03 agrees with git check-ref-format including raw non-UTF-8 ref bytes" do
    GitOracle.with_repo do |root|
      candidates = ["refs/heads/main", "refs/heads/nested/feature+one", "refs/heads/topic@host", "refs/heads/@",
                    "refs/custom/valid", "refs/tags/v1.2.3", "refs/heads/-dash", "refs/heads/name=equal",
                    "refs/heads/\u00e9tage", "refs/heads/a.locked", String.new(Bytes[114, 101, 102, 115, 47, 104, 101, 97, 100, 115, 47, 0xff]),
                    "", "@", "HEAD", "refs/heads/x..y", "refs/heads/x//y", "refs/heads/x.lock",
                    "refs/heads/.dot", "refs/heads/dot.", "refs/heads/no space", "refs/heads/x~y", "refs/heads/x^y",
                    "refs/heads/x:y", "refs/heads/x?y", "refs/heads/x*y", "refs/heads/x[y", "refs/heads/x\\y",
                    "refs/heads/x@{1}", "refs/heads/x\n", "refs/heads/x\u007f", "refs/heads/x\0z", "/refs/heads/x"]
      candidates.each do |name|
        next if name.includes?('\0') # cannot pass a NUL through execve argv
        expected = GitOracle.run(root, "check-ref-format", name, check: false).success?
        Git::RefName.valid?(name).should eq(expected), "refname bytes=#{name.to_slice.hexstring}"
      end
      Git::RefName.valid?("refs/heads/x\0z").should be_false
      GitOracle.run(root, "commit", "--allow-empty", "-qm", "base")
      GitOracle.run(root, "branch", "feature+one")
      Git::Repository.new(root).refs.resolve?("refs/heads/feature+one").should eq(GitOracle.run(root, "rev-parse", "HEAD").stdout.strip)
    end
  end

  it "P04-O04 emits Git-compatible C-style patch path quoting" do
    GitOracle.with_repo do |root|
      names = ["has space", "tab\tname", "line\nname", "back\\slash", "double\"quote", "caf\u00e9.txt", String.new(Bytes[0xff, 0x61])]
      ["old\n", "new\n"].each do |content|
        names.each { |name| File.write(File.join(root, name), content) if GitOracle.storable?(name) }
        GitOracle.run(root, "add", "--all")
        names.each { |name| GitOracle.stage_blob(root, name, content) unless GitOracle.storable?(name) }
        GitOracle.run(root, "commit", "-qm", "baseline") if content == "old\n"
      end
      store = Git::Repository.new(root)
      names.each do |name|
        staged = store.staged_file(name, max_bytes: 128 * 1024).not_nil!
        staged.path.should eq(name)
        patch = store.diff(cached: true, paths: [name]).to_s
        oracle = GitOracle.run(root, "-c", "core.quotePath=true", "diff", "--cached", "--", name).stdout
        patch.should eq(oracle), "path hex=#{name.to_slice.hexstring}"
        oracle_headers = oracle.lines.select { |line| line.starts_with?("diff --git ") || line.starts_with?("--- ") || line.starts_with?("+++ ") }
        native_headers = patch.lines.select { |line| line.starts_with?("diff --git ") || line.starts_with?("--- ") || line.starts_with?("+++ ") }
        native_headers.should eq(oracle_headers), "path hex=#{name.to_slice.hexstring}"
      end
    end
  end
end

describe "Git path and ref edge conditions" do
  it "P04-O05 preserves symlink, executable, and gitlink tree modes" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "executable"), "#!/bin/sh\n")
      File.chmod(File.join(root, "executable"), 0o755)
      File.symlink("target", File.join(root, "symlink"))
      GitOracle.run(root, "add", "executable", "symlink")
      GitOracle.run(root, "commit", "-qm", "mode base")
      head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{head},gitlink")
      GitOracle.run(root, "commit", "-qm", "add gitlink")
      tree = Git::Repository.new(root).head_directory(".", max_bytes: 128 * 1024).to_h { |entry| {entry.name, {entry.mode, entry.oid}} }
      tree["executable"][0].should eq("100755")
      tree["symlink"][0].should eq("120000")
      tree["gitlink"].should eq({"160000", head})
      native_staged = Git::Repository.new(root).staged_changes(max_bytes: 128 * 1024, limit: 20)
      native_staged.should be_empty
      GitOracle.run(root, "ls-tree", "-z", "HEAD").stdout.should contain("160000 commit #{head}\tgitlink\0")
    end
  end

  it "P04-O06 validates every non-NUL inserted ref byte against Git's grammar" do
    GitOracle.with_repo do |root|
      (1..255).each do |byte|
        name = "refs/heads/pre" + String.new(Bytes[byte.to_u8]) + "post"
        oracle = GitOracle.run(root, "check-ref-format", name, check: false).success?
        Git::RefName.valid?(name).should eq(oracle), "byte=#{byte}"
      end
      ["a/", "/a", "a//b", "a/.b", "a/b.lock", "a/../b", "a/b@{c}", "a/b.", "a/b ", "a/\tb"].each do |name|
        Git::RefName.valid?(name).should be_false
      end
    end
  end

  it "P04-O07 rejects path traversal and keeps raw/ref byte display separate" do
    ["", ".", "..", "a/..", "a/./b", "/absolute", "a//b", "a/", ".git/config", ".GIT/config", "a\0b"].each do |bad|
      expect_raises(Git::Error) { Git::PathBytes.validate_relative!(bad) }
    end
    raw = String.new(Bytes[0xff, 0x61, 0x0a, 0x22])
    value = Git::PathBytes.new(raw)
    value.utf8?.should be_false
    value.hex.should eq("ff610a22")
    value.raw.to_slice.should eq(raw.to_slice)
    value.display.should eq(%("\\377a\\n\\""))
    ["", ".", "..", "nested/name", "a\0b"].each do |name|
      expect_raises(Git::Error) { Git::PathBytes.validate_tree_name!(name) }
    end
  end

  it "P04-O08 resolves packed refs with byte-exact UTF-8 and non-UTF-8 branch names" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "commit", "--allow-empty", "-qm", "base")
      opaque = String.new(Bytes[0xff, 0x72, 0x61, 0x77])
      expected = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      GitOracle.run(root, "branch", "branch+plus")
      GitOracle.run(root, "branch", opaque) if GitOracle::RAW_NAMES
      GitOracle.run(root, "pack-refs", "--all", "--prune")
      unless GitOracle::RAW_NAMES
        # Git makes a branch as a loose ref first, a file the file system
        # refuses under this name; its packed line, which sorts last, is
        # written as pack-refs writes one, and Git must read it back.
        File.open(File.join(root, ".git", "packed-refs"), "a") { |io| io << expected << " refs/heads/" << opaque << '\n' }
        GitOracle.run(root, "rev-parse", "refs/heads/" + opaque).stdout.strip.should eq(expected)
      end
      store = Git::Repository.new(root)
      store.refs.resolve?("refs/heads/branch+plus").should eq(expected)
      store.refs.resolve?("refs/heads/" + opaque).should eq(expected)
      store.refs.list("refs/heads/").map(&.name).should contain("refs/heads/" + opaque)
    end
  end
end

describe "Git byte-exact status and serialization" do
  it "P04-O09 retains a new invalid-UTF8 untracked name and raw NUL diff bytes" do
    GitOracle.with_repo do |root|
      name = String.new(Bytes[0xff, 0x75, 0x6e, 0x74, 0x72, 0x61, 0x63, 0x6b, 0x65, 0x64])
      # An untracked file under such a name exists only where the file
      # system takes the name.
      if GitOracle::RAW_NAMES
        File.write(File.join(root, name), "new\n")
        output = GitOracle.run(root, "status", "--porcelain=v2", "-z", "--untracked-files=all").stdout
        output.includes?(name + "\0").should be_true
        changes = Git::Repository.new(root).working_changes(max_bytes: 128 * 1024, limit: 20)
        truncated = changes.truncated?
        truncated.should be_false
        changes.map(&.path).should eq([name])
        GitOracle.run(root, "add", "--", name)
      else
        GitOracle.stage_blob(root, name, "new\n")
      end
      staged = Git::Repository.new(root).staged_changes(max_bytes: 128 * 1024, limit: 20)
      staged.map(&.path).should eq([name])
      raw = GitOracle.run(root, "diff", "--cached", "--raw", "-z").stdout
      raw.includes?(name + "\0").should be_true
      recorded = Git::Index::Change.new(name, "added", nil, staged.first.index_oid, 0, nil, "100644")
      encoded = JSON.parse(recorded.to_json)
      encoded["path_raw_hex"].as_s.should eq(name.to_slice.hexstring)
      encoded["path"].as_s.should eq(Git::PathBytes.quote(name))
    end
  end
end
