require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git rename pairing and content preservation" do
  sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
  ["sha1", "sha256"].each do |format|
    ["same-destination", "divergent", "binary", "below-threshold", "ambiguous", "rename-add", "divergent-binary"].each do |scenario|
      it "matches #{format} #{scenario} rename stages and worktree bytes" do
        GitOracle.with_repo(format: format) do |root|
          original = scenario.ends_with?("binary") ? "\0" + "A" * 319 : (0...20).map { |i| "line #{i}: stable content\n" }.join
          File.write(File.join(root, "old"), original)
          File.write(File.join(root, "another"), original) if scenario == "ambiguous"
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          GitOracle.run(root, "mv", "old", scenario.starts_with?("divergent") ? "remote" : "new") unless scenario == "rename-add"
          if scenario == "ambiguous"
            GitOracle.run(root, "rm", "another")
          end
          theirs = case scenario
                   when "binary", "divergent-binary" then original.byte_slice(0, 256) + "B" * 64
                   when "below-threshold"            then "entirely different\n"
                   else                                   original.sub("line 2:", "remote edit:")
                   end
          File.write(File.join(root, scenario == "rename-add" ? "old" : scenario.starts_with?("divergent") ? "remote" : "new"), theirs)
          File.write(File.join(root, "new"), "independent addition\n") if scenario == "rename-add"
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "topic")
          GitOracle.run(root, "checkout", "-q", "main")
          destination = case scenario
                        when "same-destination", "rename-add" then "new"
                        when "divergent", "divergent-binary"  then "local"
                        else                                       "old"
                        end
          GitOracle.run(root, "mv", "old", destination) unless destination == "old"
          ours = scenario.ends_with?("binary") ? "\0" + "C" * 63 + original.byte_slice(64) : original.sub("line 15:", "local edit:")
          File.write(File.join(root, destination), ours)
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "main")
          oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
          {0, 1}.should contain(oracle.exit_code)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_files = {} of String => String
          Dir.children(root).each do |name|
            expected_files[name] = File.read(File.join(root, name)) unless name == ".git"
          end
          GitOracle.run(root, "merge", "--abort")
          repo = Git::Repository.new(root)
          result = repo.merge("topic", author: sig, committer: sig, message: "merge")
          result.conflicts.empty?.should eq(oracle.exit_code == 0)
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          actual = {} of String => String
          Dir.children(root).each do |name|
            actual[name] = File.read(File.join(root, name)) unless name == ".git"
          end
          actual.should eq(expected_files)
          repo.merge.abort unless result.conflicts.empty?
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end

describe "Git symlink rename content" do
  ["sha1", "sha256"].each do |format|
    ["same-destination", "edited-target"].each do |scenario|
      it "merges #{format} exact symlink rename with #{scenario}" do
        GitOracle.with_repo(format: format) do |root|
          File.symlink("base-target", File.join(root, "old"))
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          if scenario == "same-destination"
            GitOracle.run(root, "mv", "old", "new")
          else
            File.delete(File.join(root, "old"))
            File.symlink("edited-target", File.join(root, "old"))
          end
          File.write(File.join(root, "topic-file"), "topic\n")
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "topic")
          GitOracle.run(root, "checkout", "-q", "main")
          GitOracle.run(root, "mv", "old", "new")
          File.write(File.join(root, "main-file"), "main\n")
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "main")
          GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
          expected = GitOracle.run(root, "write-tree").stdout.strip
          GitOracle.run(root, "merge", "--abort")
          sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
          repo = Git::Repository.new(root)
          repo.merge("topic", author: sig, committer: sig, message: "merge").conflicts.should be_empty
          GitOracle.run(root, "write-tree").stdout.strip.should eq(expected)
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
