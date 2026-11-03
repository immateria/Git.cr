require "spec"
require "../src/git"
require "./support/git_oracle"

describe "default rebase original-empty policy" do
  ["sha1", "sha256"].each do |format|
    it "D2 keeps originally-empty #{format} commits but drops became-empty commits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "T0")
        GitOracle.run(root, "commit", "--allow-empty", "-qm", "T1-empty")
        original_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "upstream"), "upstream\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "M0")
        GitOracle.run(root, "checkout", "-q", "topic")
        oracle = GitOracle.run(root, "rebase", "main", check: false)
        oracle.success?.should be_true
        subjects = GitOracle.run(root, "log", "--reverse", "--format=%s", "main..HEAD").stdout
        subjects.should eq("T0\nT1-empty\n")
        GitOracle.run(root, "reset", "--hard", original_head)
        native = Git::Repository.new(root).rebase("main", committer: Git::Signature.new("R", "r@example.test", 1234567890_i64, 0))
        native.completed.should be_true
        GitOracle.run(root, "log", "--reverse", "--format=%s", "main..HEAD").stdout.should eq(subjects)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
