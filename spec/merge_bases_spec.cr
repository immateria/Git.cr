require "spec"
require "../src/git"
require "./support/git_oracle"

private module MergeBasesFixture
  def self.commit(repo : Git::Repository, files : Hash(String, String), parents : Array(String), time : Int64) : String
    entries = files.map { |name, data| Git::Tree::Entry.new(name, "100644", repo.write_blob(data)) }
    sig = Git::Signature.new("Bases", "bases@example.test", time, 0)
    repo.write_commit(tree: repo.write_tree(entries), parents: parents, author: sig, committer: sig, message: "fixture\n")
  end

  def self.history(root : String, conflict : Bool, same_time : Bool = false) : {Git::Repository, String, String}
    repo = Git::Repository.new(root)
    original = {"a" => "a\n", "b" => "b\n", "f" => "base\n"}
    first = commit(repo, original, [] of String, 1234567890_i64)
    left_files = original.merge(conflict ? {"f" => "left\n"} : {"a" => "left\n"})
    right_files = original.merge(conflict ? {"f" => "right\n"} : {"b" => "right\n"})
    left = commit(repo, left_files, [first], 1234567891_i64)
    right = commit(repo, right_files, [first], same_time ? 1234567891_i64 : 1234567892_i64)
    combined = original.merge({"a" => "left\n", "b" => "right\n"})
    ours_files = conflict ? original.merge({"f" => "left\n"}) : combined.merge({"x" => "ours\n"})
    theirs_files = conflict ? original.merge({"f" => "right\n"}) : combined.merge({"y" => "theirs\n"})
    ours = commit(repo, ours_files, [left, right], 1234567893_i64)
    theirs = commit(repo, theirs_files, [right, left], 1234567894_i64)
    GitOracle.run(root, "update-ref", "refs/heads/main", ours)
    GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
    GitOracle.run(root, "reset", "--hard", "main")
    {repo, ours, theirs}
  end
end

describe "Git recursive merge bases" do
  ["sha1", "sha256"].each do |format|
    [false, true].each do |conflicting_base|
      it "merges #{format} criss-cross history with conflicting_base=#{conflicting_base}" do
        GitOracle.with_repo(format: format) do |root|
          repo, ours, theirs = MergeBasesFixture.history(root, conflicting_base)
          repo.merge_bases(ours, theirs).size.should eq(2)
          oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
          oracle.exit_code.should eq(conflicting_base ? 1 : 0)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_content = File.read(File.join(root, "f"))
          expected_tree = GitOracle.run(root, "write-tree").stdout.strip unless conflicting_base
          GitOracle.run(root, "merge", "--abort")
          sig = Git::Signature.new("Bases", "bases@example.test", 1234567895_i64, 0)
          result = repo.merge("topic", author: sig, committer: sig, message: "merge")
          if conflicting_base
            result.conflicts.should eq(["f"])
            GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
            File.read(File.join(root, "f")).should eq(expected_content)
            repo.merge.abort
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
          else
            result.conflicts.should be_empty
            repo.read_commit(result.commit_oid.not_nil!).tree.should eq(expected_tree)
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
          GitOracle.run(root, "fsck", "--strict").success?.should be_true
        end
      end
    end

    it "leaves #{format} refs and metadata untouched on a recursive history budget failure" do
      GitOracle.with_repo(format: format) do |root|
        repo, ours, _ = MergeBasesFixture.history(root, false)
        sig = Git::Signature.new("Bases", "bases@example.test", 1234567895_i64, 0)
        expect_raises(Git::Error, /budget/) do
          repo.merge("topic", author: sig, committer: sig, message: "merge", max_history_nodes: 1)
        end
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
      end
    end
  end
end

describe "Git recursive base bounds" do
  ["sha1", "sha256"].each do |format|
    it "folds three #{format} independent common ancestors" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        original = {"a" => "a\n", "b" => "b\n", "c" => "c\n"}
        first = MergeBasesFixture.commit(repo, original, [] of String, 1234567890_i64)
        bases = ["a", "b", "c"].map_with_index do |name, index|
          MergeBasesFixture.commit(repo, original.merge({name => "#{name} changed\n"}), [first], 1234567891_i64 + index)
        end
        combined = {"a" => "a changed\n", "b" => "b changed\n", "c" => "c changed\n"}
        ours = MergeBasesFixture.commit(repo, combined.merge({"x" => "x\n"}), bases, 1234567894_i64)
        theirs = MergeBasesFixture.commit(repo, combined.merge({"y" => "y\n"}), bases.reverse, 1234567895_i64)
        GitOracle.run(root, "update-ref", "refs/heads/main", ours)
        GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
        GitOracle.run(root, "reset", "--hard", "main")
        repo.merge_bases(ours, theirs).size.should eq(3)
        GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
        expected = GitOracle.run(root, "write-tree").stdout.strip
        GitOracle.run(root, "merge", "--abort")
        sig = Git::Signature.new("Bases", "bases@example.test", 1234567896_i64, 0)
        result = repo.merge("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        repo.read_commit(result.commit_oid.not_nil!).tree.should eq(expected)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "cancels #{format} virtual base construction without publishing mutable state" do
      GitOracle.with_repo(format: format) do |root|
        repo, ours, theirs = MergeBasesFixture.history(root, false)
        before = GitOracle.run(root, "ls-files", "-s").stdout
        check = -> { raise Git::Error.new("cancelled virtual base") }
        builder = Git::Merge::Bases.new(repo, 100, 1024, 4096_i64, 100, check)
        expect_raises(Git::Error, /cancelled virtual base/) { builder.combine(ours, theirs) }
        GitOracle.run(root, "ls-files", "-s").stdout.should eq(before)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
      end
    end
  end
end

describe "Git merge-base date ties" do
  ["sha1", "sha256"].each do |format|
    it "preserves #{format} virtual base ordering when ancestor dates tie" do
      GitOracle.with_repo(format: format) do |root|
        repo, _, _ = MergeBasesFixture.history(root, true, same_time: true)
        GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
        expected = GitOracle.run(root, "ls-files", "-s").stdout
        GitOracle.run(root, "merge", "--abort")
        sig = Git::Signature.new("Bases", "bases@example.test", 1234567896_i64, 0)
        repo.merge("topic", author: sig, committer: sig, message: "merge")
        GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected)
        repo.merge.abort
      end
    end
  end
end
