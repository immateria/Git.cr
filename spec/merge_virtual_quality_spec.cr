require "spec"
require "../src/git"
require "./support/git_oracle"

private module VirtualQualityFixture
  def self.commit(repo : Git::Repository, file : {String, String}?, parents : Array(String), time : Int64) : String
    entries = [] of Git::Tree::Entry
    entries << Git::Tree::Entry.new("f", file[0], repo.write_blob(file[1])) if file
    sig = Git::Signature.new("Quality", "quality@example.test", time, 0)
    repo.write_commit(tree: repo.write_tree(entries), parents: parents, author: sig, committer: sig, message: "fixture\n")
  end
end

describe "Git virtual ancestor type and empty-content rules" do
  ["sha1", "sha256"].each do |format|
    ["symlink-type-change", "symlink-add", "empty-add", "same-oid-mode-change", "regular-from-symlink"].each do |scenario|
      it "preserves #{format} #{scenario} ancestor mode and content" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          original, left_file, right_file, ours_file, theirs_file = case scenario
                                                                    when "symlink-type-change"
                                                                      { {"100644", "base\n"}, {"120000", "left\n"}, {"120000", "right\n"}, {"120000", "base\n"}, {"100644", "theirs\n"} }
                                                                    when "symlink-add"
                                                                      {nil, {"120000", "left"}, {"120000", "right"}, {"100644", "ours\n"}, {"100644", "theirs\n"}}
                                                                    when "empty-add"
                                                                      {nil, {"100644", "left\n"}, {"100644", ""}, {"100644", "left\n"}, {"100644", "theirs\n"}}
                                                                    when "same-oid-mode-change"
                                                                      {nil, {"100644", "base\n"}, {"100755", "base\n"}, {"100644", "ours\n"}, {"100644", "theirs\n"}}
                                                                    else
                                                                      { {"120000", "base"}, {"100644", "\0left"}, {"100644", "\0right"}, {"100644", "base"}, {"100644", "\0theirs"} }
                                                                    end
          first = VirtualQualityFixture.commit(repo, original, [] of String, 1234567890_i64)
          left = VirtualQualityFixture.commit(repo, left_file, [first], 1234567891_i64)
          right = VirtualQualityFixture.commit(repo, right_file, [first], 1234567892_i64)
          ours = VirtualQualityFixture.commit(repo, ours_file, [left, right], 1234567893_i64)
          theirs = VirtualQualityFixture.commit(repo, theirs_file, [right, left], 1234567894_i64)
          GitOracle.run(root, "update-ref", "refs/heads/main", ours)
          GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
          GitOracle.run(root, "reset", "--hard", "main")
          oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
          {0, 1}.should contain(oracle.exit_code)
          # Type conflicts can relocate Git's stage-one path; compare its mode
          # and OID independently of the bounded worktree conflict layout.
          expected_bases = GitOracle.run(root, "ls-files", "-u").stdout.lines.select { |line| line.split('\t', 2)[0].ends_with?(" 1") }
            .map { |line| line.split('\t', 2)[0].split(' ')[0, 2] }.sort
          expected_tree = GitOracle.run(root, "write-tree").stdout.strip if oracle.exit_code == 0
          GitOracle.run(root, "merge", "--abort")
          sig = Git::Signature.new("Quality", "quality@example.test", 1234567895_i64, 0)
          result = repo.merge("topic", author: sig, committer: sig, message: "merge")
          result.conflicts.empty?.should eq(oracle.exit_code == 0)
          if oracle.exit_code == 0
            GitOracle.run(root, "write-tree").stdout.strip.should eq(expected_tree)
          else
            actual_bases = repo.merge.conflicts.compact_map(&.base).map { |state| [state.mode, state.oid] }.sort
            actual_bases.should eq(expected_bases)
            repo.merge.abort
          end
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
