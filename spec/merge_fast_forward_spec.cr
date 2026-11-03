require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P28 native fast-forward-only merge" do
  ["sha1", "sha256"].each do |format|
    it "P28-O01 fast-forwards a clean #{format} branch preserving target content" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "existing"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "existing"), "later\n")
        File.write(File.join(root, "new"), "new\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        target = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        result = repo.merge_fast_forward("topic")
        result.previous_oid.should eq(base)
        result.target_oid.should eq(target)
        result.changed_paths.to_set.should eq(["existing", "new"].to_set)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(target)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.read(File.join(root, "existing")).should eq("later\n")
        File.read(File.join(root, "new")).should eq("new\n")
        repo.merge_fast_forward("topic").changed_paths.should be_empty
      end
    end

    it "P28-O02 rejects a dirty #{format} tree or staged change" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "one"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "branch", "topic")
        repo = Git::Repository.new(root)
        File.write(File.join(root, "one"), "dirty\n")
        expect_raises(Git::Error, /dirty tracked/) { repo.merge_fast_forward("topic") }
        GitOracle.run(root, "add", "one")
        expect_raises(Git::Error, /index equal to HEAD/) { repo.merge_fast_forward("topic") }
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
      end
    end

    it "P28-O03 refuses a non-fast-forward #{format} DAG" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", "topic")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", "main")
        GitOracle.run(root, "commit", "-qm", "main")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /not a fast-forward/) { repo.merge_fast_forward("topic") }
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(main)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
