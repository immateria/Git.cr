require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P18/P19 native staging and branch commit workflow" do
  ["sha1", "sha256"].each do |format|
    it "P19-O03 commits nested staged files and updates #{format} HEAD" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Crystal", "crystal@example.invalid", 1_700_000_000_i64, 0)
        repo.stage_blob("one", "one\n")
        repo.stage_blob("sub/two", "two\n", mode: "100755")
        tree = repo.write_index_tree
        tree.should eq(GitOracle.run(root, "write-tree").stdout.strip)
        first = repo.commit_staged(author: sig, committer: sig, message: "Initial\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(first)
        GitOracle.run(root, "ls-tree", "-r", "HEAD").stdout.should contain("sub/two")
        repo.head[1].should eq(first)
        expect_raises(Git::Error, /nothing staged/) do
          repo.commit_staged(author: sig, committer: sig, message: "not needed\n")
        end
        Dir.mkdir(File.join(root, "sub"))
        File.write(File.join(root, "sub", "three"), "three\n")
        repo.stage_file("sub/three")
        second = repo.commit_staged(author: sig, committer: sig, message: "Second\n")
        GitOracle.run(root, "rev-list", "--count", "HEAD").stdout.strip.should eq("2")
        reflog = GitOracle.run(root, "reflog", "show", "--format=%gs", "HEAD").stdout
        reflog.should contain("commit (initial): Initial")
        reflog.should contain("commit: Second")
        GitOracle.run(root, "rev-parse", "HEAD^").stdout.strip.should eq(first)
        repo.commit(second, 4096) { nil }.parents.should eq([first])
        GitOracle.run(root, "fsck", "--no-reflogs")
      end
    end
  end
end

describe "P18/P19 native write refusal boundaries" do
  it "P18-O04 stages symlink targets without following them and refuses unsafe paths" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      File.write(File.join(root, "real"), "content")
      repo.stage_file("real")
      index = File.read(File.join(root, ".git", "index"))
      File.symlink("real", File.join(root, "link"))
      oid = repo.stage_file("link")
      oid.should eq(Git::ObjectId.digest("blob", "real", repo.object_format))
      GitOracle.run(root, "ls-files", "--stage", "link").stdout.should eq("120000 #{oid} 0\tlink\n")
      File.read(File.join(root, "real")).should eq("content")
      File.read(File.join(root, ".git", "index")).should_not eq(index)
      updated = File.read(File.join(root, ".git", "index"))
      expect_raises(Git::Error, /unsafe/) { repo.stage_blob("../outside", "x") }
      File.read(File.join(root, ".git", "index")).should eq(updated)
    end
  end

  it "P19-O05 refuses a redirected reflog before publishing a branch" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Crystal", "crystal@example.invalid", 1_700_000_000_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      commit = repo.write_commit(tree: tree, author: sig, committer: sig, message: "first")
      log = File.join(root, ".git", "logs", "refs", "heads", "main")
      Dir.mkdir_p(File.dirname(log))
      File.symlink(File.join(root, "no-such-log"), log)
      expect_raises(Git::Error, /reflog symlink/) do
        repo.update_ref("refs/heads/main", commit, expected_oid: nil,
          log: Git::References::LogEntry.new(sig, "commit: first"))
      end
      repo.head[1].should be_nil
      File.exists?(File.join(root, ".git", "refs", "heads", "main.lock")).should be_false
    end
  end
end

describe "P19 empty initial commit semantics" do
  it "P19-O06 refuses an empty initial commit unless explicitly allowed" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      sig = Git::Signature.new("Crystal", "crystal@example.invalid", 1_700_000_000_i64, 0)
      expect_raises(Git::Error, /nothing staged/) do
        repo.commit_staged(author: sig, committer: sig, message: "empty")
      end
      repo.head[1].should be_nil
      oid = repo.commit_staged(author: sig, committer: sig, message: "empty", allow_empty: true)
      GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(oid)
    end
  end
end
