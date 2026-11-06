require "spec"
require "../src/git"
require "./support/git_oracle"

describe "EOL conversion index budgets" do
  it "stages a small file with an independently bounded larger index" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      8.times { |i| repository.stage_blob("kept-#{i}", "kept\n") }
      File.size(File.join(root, ".git", "index")).should be > 128
      File.write(File.join(root, "file.txt"), "one\r\n")
      config = repository.config(command_values: [{"core.autocrlf", "true"}])
      repository.stage_file("file.txt", config: config,
        max_bytes: 128, max_index_bytes: 8192).should eq(Git::ObjectId.digest("blob", "one\n"))
      GitOracle.run(root, "show", ":file.txt").stdout.should eq("one\n")
    end
  end

  it "normalizes a small working diff without imposing its blob limit on the index" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      8.times do |i|
        File.write(File.join(root, "kept-#{i}"), "kept\n")
        repository.stage_blob("kept-#{i}", "kept\n")
      end
      repository.stage_blob("file.txt", "one\n")
      File.write(File.join(root, "file.txt"), "two\r\n")
      config = repository.config(command_values: [{"core.autocrlf", "true"}])
      expected = GitOracle.run(root, "-c", "core.autocrlf=true", "diff", "--no-color").stdout
      repository.diff(config: config, max_bytes: 128).to_s.should eq(expected)
    end
  end
end

describe "EOL hard reset attribute sources" do
  it "discards invalid worktree attributes using the valid target-tree rules" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      attributes = "*.txt text eol=crlf\n"
      File.write(File.join(root, ".gitattributes"), attributes)
      File.write(File.join(root, "file.txt"), "one\r\n")
      repository.stage
      signature = Git::Signature.new("EOL Reset", "eol-reset@example.invalid", 1_700_000_000_i64, 0)
      repository.commit(author: signature, committer: signature, message: "base")
      File.write(File.join(root, ".gitattributes"), "invalid\0attributes\n")
      File.write(File.join(root, "file.txt"), "dirty\n")
      GitOracle.run(root, "reset", "--hard")
      File.read(File.join(root, "file.txt")).should eq("one\r\n")
      File.write(File.join(root, ".gitattributes"), "invalid\0attributes\n")
      File.write(File.join(root, "file.txt"), "dirty\n")
      repository.reset(mode: Git::Reset::Mode::Hard)
      File.read(File.join(root, ".gitattributes")).should eq(attributes)
      File.read(File.join(root, "file.txt")).should eq("one\r\n")
      GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
    end
  end
end
