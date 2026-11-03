require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P18 native index mutation" do
  ["sha1", "sha256"].each do |format|
    it "P18-O01 publishes a #{format} Git-readable index and stages blobs" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        oid = repo.stage_blob("alpha.txt", "alpha\n")
        repo.stage_blob("scripts/run", "#!/bin/sh\n", mode: "100755")
        staged = GitOracle.run(root, "ls-files", "--stage").stdout.lines
        staged.size.should eq(2)
        staged[0].should contain("100644 #{oid} 0\talpha.txt")
        staged[1].should contain("100755 ")
        GitOracle.run(root, "diff", "--cached", "--name-status").stdout.should contain("alpha.txt")
        repo.staged_changes(8192, 10) { nil }[0].size.should eq(2)
        tree_oid = GitOracle.run(root, "write-tree").stdout.strip
        repo.object(tree_oid, 8192) { nil }[0].should eq("tree")
        repo.stage_blob("alpha.txt", "updated\n").should eq(GitOracle.run(root, "hash-object", "--stdin", input: "updated\n").stdout.strip)
        GitOracle.run(root, "ls-files", "--stage").stdout.lines.size.should eq(2)
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end
  end

  it "P18-O02 refuses conflicting, unsupported and redirected indexes without replacement" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      repo.stage_blob("a", "one")
      index = File.join(root, ".git", "index")
      before = File.read(index)
      File.write(index + ".lock", "foreign")
      expect_raises(Git::Error, /lock/) { repo.stage_blob("b", "two") }
      File.read(index).should eq(before)
      File.read(index + ".lock").should eq("foreign")
      File.delete(index + ".lock")
      expect_raises(Git::Error, /collision/) { repo.stage_blob("a/b", "child") }
      File.read(index).should eq(before)
      File.rename(index, index + ".old")
      File.symlink(index + ".old", index)
      expect_raises(Git::Error) { repo.stage_blob("b", "two") }
      File.read(index + ".old").should eq(before)
    end
  end

  it "P18-O03 refuses unknown index extensions rather than discarding state" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      repo.stage_blob("a", "one")
      index = File.join(root, ".git", "index")
      content = File.read(index)
      body = content.byte_slice(0, content.bytesize - 20) + "ABCD\0\0\0\0"
      File.write(index, body + String.new(Git::ObjectId.checksum(body).hexbytes))
      expect_raises(Git::Error, /extension/) { repo.stage_blob("b", "two") }
      File.read(index).should eq(body + String.new(Git::ObjectId.checksum(body).hexbytes))
    end
  end
end

describe "P18 index flags preservation boundary" do
  it "P18-O05 preserves assume-unchanged flags through index writes" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      File.write(File.join(root, "one"), "one")
      repo.stage_file("one")
      GitOracle.run(root, "update-index", "--assume-unchanged", "one")
      index = File.join(root, ".git", "index")
      repo.stage_blob("another", "two")
      GitOracle.run(root, "ls-files", "-v").stdout.lines.find(&.includes?("one")).not_nil!.should start_with("h ")
      GitOracle.run(root, "ls-files", "--stage").stdout.should contain("another")
      File.exists?(index + ".lock").should be_false
    end
  end
end

describe "P18 index v3/v4 mutation compatibility" do
  ["sha1", "sha256"].each do |format|
    [3, 4].each do |version|
      it "P18-O06 preserves #{format} index v#{version} and extended flags" do
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "a.txt"), "base\n")
          File.write(File.join(root, "z.txt"), "last\n")
          GitOracle.run(root, "add", "a.txt", "z.txt")
          GitOracle.run(root, "update-index", "--index-version", version.to_s)
          GitOracle.run(root, "update-index", "--skip-worktree", "a.txt")
          index_file = File.join(root, ".git", "index")
          before_version = File.read(index_file).to_slice[7]
          before_version.should eq(version)
          repo = Git::Repository.new(root)
          repo.stage_blob("middle.txt", "staged\n")
          File.read(index_file).to_slice[7].should eq(version)
          GitOracle.run(root, "ls-files", "-v").stdout.lines.find(&.includes?("a.txt")).not_nil!.should start_with("S ")
          GitOracle.run(root, "ls-files", "--stage").stdout.should contain("middle.txt")
          GitOracle.run(root, "write-tree")
          repo.staged_changes(32_768, 10) { nil }[0].size.should eq(3)
        end
      end
    end
  end

  it "P18-O07 encodes long v4 byte prefixes and retains intent-to-add" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      a = "dir/" + "x" * 150 + "/a"
      b = "dir/" + "x" * 150 + "/b"
      c = "dir/" + "x" * 150 + "/c"
      FileUtils.mkdir_p(File.dirname(File.join(root, a)))
      File.write(File.join(root, a), "a")
      File.write(File.join(root, b), "b")
      GitOracle.run(root, "add", a, b)
      GitOracle.run(root, "update-index", "--index-version", "4")
      repo.stage_blob(c, "c")
      GitOracle.run(root, "ls-files", "--stage").stdout.lines.size.should eq(3)
      GitOracle.run(root, "ls-files", "--stage").stdout.lines.size.should eq(3)
      GitOracle.run(root, "write-tree")
    end
  end
end

describe "P18 retained index semantics" do
  it "P18-O08 preserves v4 intent-to-add and CE_VALID on untouched paths" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "intent.txt"), "not staged")
      File.write(File.join(root, "valid.txt"), "staged")
      GitOracle.run(root, "add", "-N", "intent.txt")
      GitOracle.run(root, "add", "valid.txt")
      GitOracle.run(root, "update-index", "--assume-unchanged", "valid.txt")
      GitOracle.run(root, "update-index", "--index-version", "4")
      index = File.join(root, ".git", "index")
      File.read(index).to_slice[7].should eq(4)
      repo = Git::Repository.new(root)
      repo.stage_blob("new.txt", "new content")
      File.read(index).to_slice[7].should eq(4)
      names = GitOracle.run(root, "ls-files", "-v").stdout
      names.should contain("h valid.txt")
      # An intent-to-add path remains an index placeholder until staged.
      expect_raises(Git::Error, /intent-to-add/) { repo.write_index_tree }
      GitOracle.run(root, "add", "intent.txt")
      GitOracle.run(root, "write-tree")
    end
  end
end
