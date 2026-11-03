require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P31 native Git file/directory transitions" do
  ["sha1", "sha256"].each do |format|
    it "P31-O01 merges a clean #{format} file-to-directory transition" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node"))
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "child\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "ours"), "local\n")
        GitOracle.run(root, "add", "ours")
        GitOracle.run(root, "commit", "-qm", "ours")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        result.commit_oid.should_not be_nil
        File.directory?(File.join(root, "node")).should be_true
        File.read(File.join(root, "node", "child")).should eq("child\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P31-O02 merges a clean #{format} directory-to-file transition" do
      GitOracle.with_repo(format: format) do |root|
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "child\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node", "child"))
        Dir.delete(File.join(root, "node"))
        File.write(File.join(root, "node"), "replacement\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "ours"), "local\n")
        GitOracle.run(root, "add", "ours")
        GitOracle.run(root, "commit", "-qm", "ours")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.file?(File.join(root, "node")).should be_true
        File.read(File.join(root, "node")).should eq("replacement\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P31-O03 refuses #{format} directory collapse that would lose untracked content" do
      GitOracle.with_repo(format: format) do |root|
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "child\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node", "child"))
        Dir.delete(File.join(root, "node"))
        File.write(File.join(root, "node"), "replacement\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "ours"), "local\n")
        GitOracle.run(root, "add", "ours")
        GitOracle.run(root, "commit", "-qm", "ours")
        File.write(File.join(root, "node", "untracked"), "keep me\n")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /untracked/) do
          repo.merge("topic", author: sig, committer: sig, message: "merge")
        end
        File.read(File.join(root, "node", "child")).should eq("child\n")
        File.read(File.join(root, "node", "untracked")).should eq("keep me\n")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end

    it "P31-O04 keeps divergent #{format} file/directory conflicts fail-closed" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "node"))
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "child\n")
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "node"), "ours changed\n")
        GitOracle.run(root, "add", "node")
        GitOracle.run(root, "commit", "-qm", "ours")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /file\/directory conflict unsupported/) do
          repo.merge("topic", author: sig, committer: sig, message: "merge")
        end
        File.read(File.join(root, "node")).should eq("ours changed\n")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end
  end
end
