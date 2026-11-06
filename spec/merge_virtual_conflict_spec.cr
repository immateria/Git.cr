require "spec"
require "../src/git"
require "./support/git_oracle"

private module VirtualConflictFixture
  def self.commit(repo : Git::Repository, files : Hash(String, String), parents : Array(String), time : Int64) : String
    sig = Git::Signature.new("Virtual", "virtual@example.test", time, 0)
    tree = repo.write_tree(files.map { |path, data| Git::Tree::Entry.new(path, "100644", repo.write_blob(data)) })
    repo.write_commit(tree: tree, parents: parents, author: sig, committer: sig, message: "fixture\n")
  end
end

describe "Git virtual conflict materialization" do
  ["sha1", "sha256"].each do |format|
    ["rename-delete", "rename-rename", "add-binary", "no-newline"].each do |scenario|
      it "retains #{format} #{scenario} virtual ancestor stages" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          original = scenario == "add-binary" ? {} of String => String : {"f" => scenario == "no-newline" ? "base" : "base\n"}
          left_files, right_files = case scenario
                                    when "rename-delete" then { {"g" => "base\n"}, {} of String => String }
                                    when "rename-rename" then { {"g" => "base\n"}, {"h" => "base\n"} }
                                    when "add-binary"    then { {"f" => "\0left"}, {"f" => "\0right"} }
                                    else                      { {"f" => "left"}, {"f" => "right"} }
                                    end
          first = VirtualConflictFixture.commit(repo, original, [] of String, 1234567890_i64)
          left = VirtualConflictFixture.commit(repo, left_files, [first], 1234567891_i64)
          right = VirtualConflictFixture.commit(repo, right_files, [first], 1234567892_i64)
          paths = (original.keys + left_files.keys + right_files.keys).uniq
          ours_files = paths.to_h { |path| {path, scenario == "add-binary" ? "\0ours" : "ours #{path}\n"} }
          theirs_files = paths.to_h { |path| {path, scenario == "add-binary" ? "\0theirs" : "theirs #{path}\n"} }
          ours = VirtualConflictFixture.commit(repo, ours_files, [left, right], 1234567893_i64)
          theirs = VirtualConflictFixture.commit(repo, theirs_files, [right, left], 1234567894_i64)
          GitOracle.run(root, "update-ref", "refs/heads/main", ours)
          GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
          GitOracle.run(root, "reset", "--hard", "main")
          GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
          expected = GitOracle.run(root, "ls-files", "-s").stdout
          GitOracle.run(root, "merge", "--abort")
          sig = Git::Signature.new("Virtual", "virtual@example.test", 1234567895_i64, 0)
          repo.merge("topic", author: sig, committer: sig, message: "merge")
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected)
          repo.merge.abort
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
