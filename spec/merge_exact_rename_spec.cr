require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P30 exact-identity Git rename during three-way merge" do
  ["sha1", "sha256"].each do |format|
    it "P30-R01 merges #{format} their rename with our content edit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        GitOracle.run(root, "mv", "old", "new")
        GitOracle.run(root, "commit", "-qm", "rename")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "old"), "locally changed\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
        oracle.exit_code.should eq(0)
        expected = File.read(File.join(root, "new"))
        GitOracle.run(root, "merge", "--abort")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        result.changed_paths.to_set.should eq(Set{"old", "new"})
        File.exists?(File.join(root, "old")).should be_false
        File.read(File.join(root, "new")).should eq(expected)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-R02 merges #{format} our rename with their content edit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "old"), "their change\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        GitOracle.run(root, "mv", "old", "new")
        GitOracle.run(root, "commit", "-qm", "rename")
        oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
        oracle.exit_code.should eq(0)
        expected = File.read(File.join(root, "new"))
        GitOracle.run(root, "merge", "--abort")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.exists?(File.join(root, "old")).should be_false
        File.read(File.join(root, "new")).should eq(expected)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-R03 refuses #{format} conflicting exact rename destinations before metadata publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        GitOracle.run(root, "mv", "old", "remote")
        GitOracle.run(root, "commit", "-qm", "remote")
        GitOracle.run(root, "checkout", "-q", "main")
        GitOracle.run(root, "mv", "old", "local")
        GitOracle.run(root, "commit", "-qm", "local")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /rename\/rename/) do
          repo.merge("topic", author: sig, committer: sig, message: "merge")
        end
        File.read(File.join(root, "local")).should eq("base\n")
        File.exists?(File.join(root, "remote")).should be_false
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end
  end
end

describe "P31 exact-content Git rename with independent mode changes" do
  ["sha1", "sha256"].each do |format|
    it "P31-R04 combines #{format} their rename+chmod with our content edit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        File.chmod(File.join(root, "old"), 0o644)
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        GitOracle.run(root, "mv", "old", "new")
        File.chmod(File.join(root, "new"), 0o755)
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "rename mode")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "old"), "ours\n")
        GitOracle.run(root, "add", "old")
        GitOracle.run(root, "commit", "-qm", "ours")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.exists?(File.join(root, "old")).should be_false
        File.read(File.join(root, "new")).should eq("ours\n")
        (File.info(File.join(root, "new")).permissions.value & 0o111).should_not eq(0)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P31-R05 combines #{format} our rename+chmod with their content edit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        File.chmod(File.join(root, "old"), 0o644)
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "old"), "theirs\n")
        GitOracle.run(root, "add", "old")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        GitOracle.run(root, "mv", "old", "new")
        File.chmod(File.join(root, "new"), 0o755)
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "rename mode")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.exists?(File.join(root, "old")).should be_false
        File.read(File.join(root, "new")).should eq("theirs\n")
        (File.info(File.join(root, "new")).permissions.value & 0o111).should_not eq(0)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
