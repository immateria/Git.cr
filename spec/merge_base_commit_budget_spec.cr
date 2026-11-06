require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git merge-base commit byte budgets" do
  ["sha1", "sha256"].each do |format|
    it "bounds #{format} ancestor payloads during a native merge before publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        tree = repo.write_tree([] of Git::Tree::Entry)
        sig = Git::Signature.new("Budget", "budget@example.test", 1234567890_i64, 0)
        oversized = repo.write_commit(tree: tree, author: sig, committer: sig, message: "x" * 2000)
        base = repo.write_commit(tree: tree, parents: [oversized], author: sig, committer: sig, message: "base")
        ours = repo.write_commit(tree: tree, parents: [base], author: sig, committer: sig, message: "ours")
        theirs = repo.write_commit(tree: tree, parents: [base], author: sig, committer: sig, message: "theirs")
        GitOracle.run(root, "update-ref", "refs/heads/main", ours)
        GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
        GitOracle.run(root, "reset", "--hard", "main")
        orig_head_path = File.join(root, ".git", "ORIG_HEAD")
        orig_head = File.exists?(orig_head_path) ? File.read(orig_head_path) : nil
        expect_raises(Git::Error, /budget|size limit/) do
          repo.merge_bases(ours, theirs, max_commit_bytes: 512)
        end
        expect_raises(Git::Error, /budget|size limit/) do
          repo.merge("topic", author: sig, committer: sig, message: "merge",
            max_object_bytes: 512, max_total_bytes: 1024_i64)
        end
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        (File.exists?(orig_head_path) ? File.read(orig_head_path) : nil).should eq(orig_head)
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
        # An exact payload budget still permits this same traversal.
        size = repo.read_object(oversized, max_bytes: 4096).data.bytesize
        repo.merge_bases(ours, theirs, max_commit_bytes: size).should eq([base])
      end
    end
  end
end
