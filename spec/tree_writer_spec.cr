require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P17 native Git tree writing" do
  ["sha1", "sha256"].each do |format|
    it "P17-O08 writes canonical #{format} trees readable by real Git" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        blob = repo.write_blob(Bytes[0_u8, 255_u8, 10_u8, 65_u8])
        sub = repo.write_tree([Git::Tree::Entry.new("child", "100755", blob)])
        opaque = String.new(Bytes[120_u8, 255_u8, 121_u8])
        entries = [
          Git::Tree::Entry.new("foo0", "100644", blob),
          Git::Tree::Entry.new("foo", "040000", sub),
          Git::Tree::Entry.new(opaque, "120000", blob),
          Git::Tree::Entry.new("foo.bar", "100644", blob),
          Git::Tree::Entry.new("foo-", "100755", blob),
          Git::Tree::Entry.new("foo.", "40000", sub),
        ]
        expected_input = String.build do |io|
          io << "100644 blob #{blob}\tfoo0\0"
          io << "040000 tree #{sub}\tfoo\0"
          io << "120000 blob #{blob}\t" << opaque << '\0'
          io << "100644 blob #{blob}\tfoo.bar\0"
          io << "100755 blob #{blob}\tfoo-\0"
          io << "40000 tree #{sub}\tfoo.\0"
        end
        expected_oid = GitOracle.run(root, "mktree", "-z", "--missing", input: expected_input).stdout.strip
        oid = repo.write_tree(entries)
        oid.should eq(expected_oid)
        stored = repo.read_object(oid, max_bytes: 4096)
        type, raw = stored.type.to_s, stored.data
        type.should eq("tree")
        GitOracle.assert_bytes!(GitOracle.run(root, "cat-file", "tree", oid).stdout, raw, "P17-O08")
        repo.write_tree(entries.reverse).should eq(oid)
        GitOracle.run(root, "fsck", "--no-reflogs", "--unreachable")
      end
    end
  end

  it "P17-O09 handles empty trees and missing referenced objects as structural data" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      empty = repo.write_tree([] of Git::Tree::Entry)
      empty.should eq(GitOracle.run(root, "mktree", "--missing", input: "").stdout.strip)
      repo.read_object(empty, max_bytes: 512).should eq(Git::RawObject.new(Git::ObjectType::Tree, ""))
      missing_oid = "a" * 40
      entry = Git::Tree::Entry.new("gitlink", "160000", missing_oid)
      tree = repo.write_tree([entry])
      expected = GitOracle.run(root, "mktree", "-z", "--missing",
        input: "160000 commit #{missing_oid}\tgitlink\0").stdout.strip
      tree.should eq(expected)
    end
  end

  it "P17-O10 rejects invalid tree structure without writing an object" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      blob = repo.write_blob("v")
      objects = File.join(root, ".git", "objects")
      before = Dir.children(objects).sort
      good = Git::Tree::Entry.new("ok", "100644", blob)
      expect_raises(Git::Error, /duplicate/) { repo.write_tree([good, good]) }
      ["", ".", "..", "bad/name", "nul\0name"].each do |name|
        expect_raises(Git::Error, /name/) { repo.write_tree([Git::Tree::Entry.new(name, "100644", blob)]) }
      end
      expect_raises(Git::Error, /mode/) { repo.write_tree([Git::Tree::Entry.new("bad", "100664", blob)]) }
      expect_raises(Git::Error, /OID/) { repo.write_tree([Git::Tree::Entry.new("bad", "100644", "INVALID")]) }
      expect_raises(Git::Error, /budget/) { repo.write_tree([good], max_entries: 0) }
      expect_raises(Git::Error, /budget/) { repo.write_tree([good], max_bytes: 2) }
      expect_raises(ArgumentError, /budget/) { repo.write_tree([good], max_bytes: -1) }
      expect_raises(ArgumentError, /budget/) { repo.write_tree([good], max_entries: -1) }
      Dir.children(objects).sort.should eq(before)
    end
  end

  it "P17-O11 preserves existing tree object identity and refuses corrupt targets" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      blob = repo.write_blob("stable")
      entries = [Git::Tree::Entry.new("file", "100644", blob)]
      oid = repo.write_tree(entries)
      path = File.join(root, ".git", "objects", oid[0, 2], oid[2..])
      inode = File.info(path)
      repo.write_tree(entries).should eq(oid)
      File.info(path).same_file?(inode).should be_true
      # Loose objects are written read-only, as Git writes them.
      File.chmod(path, 0o644)
      File.write(path, "corrupted tree")
      expect_raises(Git::Error) { repo.write_tree(entries) }
      File.read(path).should eq("corrupted tree")
    end
  end

  it "P17-O13 refuses redirected tree-object fanouts and mismatched hash formats" do
    GitOracle.with_repo(format: "sha256") do |root|
      repo = Git::Repository.new(root)
      entry = Git::Tree::Entry.new("file", "100644", "a" * 64)
      expect_raises(Git::Error, /OID/) do
        repo.write_tree([Git::Tree::Entry.new("file", "100644", "a" * 40)])
      end
      oid = Git::ObjectId.digest("tree", Git::Tree.encode([entry], repo.object_format), repo.object_format)
      fanout = File.join(root, ".git", "objects", oid[0, 2])
      outside = File.join(File.dirname(root), "outside")
      Dir.mkdir(outside)
      File.write(File.join(outside, "marker"), "untouched")
      File.symlink(outside, fanout)
      expect_raises(Git::Error, /directory/) { repo.write_tree([entry]) }
      Dir.children(outside).should eq(["marker"])
    end
  end

  it "P17-O12 refuses a prepublication cancellation without publishing a tree" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      blob = repo.write_blob("content")
      entries = [Git::Tree::Entry.new("file", "100644", blob)]
      oid = Git::ObjectId.digest("tree", Git::Tree.encode(entries, repo.object_format))
      count = 0
      expect_raises(Git::Error, /cancelled/) do
        repo.write_tree(entries, check: -> do
          count += 1
          raise Git::Error.new("cancelled") if count == 3
        end)
      end
      File.exists?(File.join(root, ".git", "objects", oid[0, 2], oid[2..])).should be_false
      count.should eq(3)
      fanout = File.join(root, ".git", "objects", oid[0, 2])
      Dir.children(fanout).should be_empty
    end
  end
end
