require "spec"
require "../src/git"
require "./support/git_oracle"

private module RenameMarkerFixture
  def self.commit(repo : Git::Repository, files : Hash(String, String), parents : Array(String), time : Int64) : String
    sig = Git::Signature.new("Markers", "markers@example.test", time, 0)
    tree = repo.write_tree(files.map { |name, data| Git::Tree::Entry.new(name, "100644", repo.write_blob(data)) })
    repo.write_commit(tree: tree, parents: parents, author: sig, committer: sig, message: "fixture\n")
  end
end

describe "Git divergent rename marker context" do
  ["sha1", "sha256"].each do |format|
    [false, true].each do |recursive|
      it "preserves #{format} recursive=#{recursive} marker labels and nesting width" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          # A single line isolates marker metadata from bounded hunk alignment.
          text = (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
          base = RenameMarkerFixture.commit(repo, {"f" => text}, [] of String, 1234567890_i64)
          left = RenameMarkerFixture.commit(repo, {"g" => text.sub("word02", "left02")}, [base], 1234567891_i64)
          right = RenameMarkerFixture.commit(repo, {"h" => text.sub("word02", "rght02")}, [base], 1234567892_i64)
          ours, theirs = if recursive
                           {RenameMarkerFixture.commit(repo, {"g" => "ours g\n", "h" => "ours h\n"}, [left, right], 1234567893_i64),
                            RenameMarkerFixture.commit(repo, {"g" => "theirs g\n", "h" => "theirs h\n"}, [right, left], 1234567894_i64)}
                         else
                           {left, right}
                         end
          GitOracle.run(root, "update-ref", "refs/heads/main", ours)
          GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
          GitOracle.run(root, "reset", "--hard", "main")
          GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
          unless recursive
            GitOracle.run(root, "ls-files", "-u").stdout.should contain(" 1\tf\n")
          end
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_content = {"g", "h"}.to_h { |name| {name, File.read(File.join(root, name))} }
          GitOracle.run(root, "merge", "--abort")
          sig = Git::Signature.new("Markers", "markers@example.test", 1234567895_i64, 0)
          repo.merge("topic", author: sig, committer: sig, message: "merge")
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          expected_content.each { |name, data| File.read(File.join(root, name)).should eq(data) }
          repo.merge.abort
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
