require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P18 explicit index-only removal" do
  ["sha1", "sha256"].each do |format|
    [2, 3, 4].each do |version|
      it "P18-O09 removes a staged path from #{format} v#{version} without touching the worktree" do
        GitOracle.with_repo(format: format) do |root|
          first_file = File.join(root, "first.txt")
          File.write(first_file, "from worktree\n")
          File.write(File.join(root, "other.txt"), "remain\n")
          GitOracle.run(root, "add", "first.txt", "other.txt")
          GitOracle.run(root, "update-index", "--index-version", version.to_s)
          GitOracle.run(root, "update-index", "--skip-worktree", "other.txt") if version == 3
          repo = Git::Repository.new(root)
          before = GitOracle.run(root, "ls-files", "--stage").stdout
          before.should contain("first.txt")
          repo.remove_from_index("first.txt")
          File.read(first_file).should eq("from worktree\n")
          staged = GitOracle.run(root, "ls-files", "--stage").stdout
          staged.should_not contain("first.txt")
          staged.should contain("other.txt")
          File.read(File.join(root, ".git", "index")).to_slice[7].should eq(version)
          GitOracle.run(root, "write-tree").stdout.strip.should eq(repo.write_index_tree)
          expect_raises(Git::Error, /not staged/) { repo.remove_from_index("first.txt") }
          File.exists?(File.join(root, ".git", "index.lock")).should be_false
        end
      end
    end
  end

  it "P18-O10 preserves the index on a refused removal and releases owned locks" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      repo.stage_blob("one", "x")
      index = File.join(root, ".git", "index")
      before = File.read(index)
      expect_raises(Git::Error, /unsafe/) { repo.remove_from_index("../outside") }
      expect_raises(Git::Error, /not staged/) { repo.remove_from_index("missing") }
      File.read(index).should eq(before)
      File.write(index + ".lock", "foreign")
      expect_raises(Git::Error, /lock/) { repo.remove_from_index("one") }
      File.read(index + ".lock").should eq("foreign")
      File.delete(index + ".lock")
      expect_raises(Git::Error, /stop/) do
        repo.remove_from_index("one", check: -> { raise Git::Error.new("stop") })
      end
      File.read(index).should eq(before)
      File.exists?(index + ".lock").should be_false
    end
  end
end
