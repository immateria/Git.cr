require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git directory conflict recovery" do
  sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
  ["sha1", "sha256"].each do |format|
    [true, false].each do |file_ours|
      ["merge", "cherry-pick", "rebase"].each do |operation|
        it "relocates #{format} #{operation} file_ours=#{file_ours} without losing collisions" do
          GitOracle.with_repo(format: format) do |root|
            File.write(File.join(root, "node"), "base\n")
            File.write(File.join(root, "node-sibling"), "preserve sibling\n")
            GitOracle.run(root, "add", ".")
            GitOracle.run(root, "commit", "-qm", "base")
            GitOracle.run(root, "checkout", "-qb", "topic")
            # Rebase replays topic onto main, swapping the merge sides.
            topic_file = !file_ours
            if topic_file
              File.write(File.join(root, "node"), "changed\n")
            else
              File.delete(File.join(root, "node"))
              Dir.mkdir(File.join(root, "node"))
              File.write(File.join(root, "node/child"), "child\n")
            end
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "topic")
            source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            GitOracle.run(root, "checkout", "-q", "main")
            if topic_file
              File.delete(File.join(root, "node"))
              Dir.mkdir(File.join(root, "node"))
              File.write(File.join(root, "node/child"), "child\n")
            else
              File.write(File.join(root, "node"), "changed\n")
            end
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "main")
            GitOracle.run(root, "checkout", "-q", "topic") if operation == "rebase"
            original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            command = operation == "merge" ? ["merge", "--no-commit", "--no-ff", "topic"] : operation == "rebase" ? ["rebase", "main"] : ["cherry-pick", source]
            GitOracle.run_args(root, command, check: false).exit_code.should eq(1)
            expected_index = GitOracle.run(root, "ls-files", "-s").stdout
            expected_status = GitOracle.run(root, "status", "--porcelain").stdout
            relocated = Dir.children(root).find { |name| name.starts_with?("node~") }.not_nil!
            expected_file = File.read(File.join(root, relocated))
            GitOracle.run(root, operation, "--abort")
            repo = Git::Repository.new(root)
            case operation
            when "merge"
              repo.merge("topic", author: sig, committer: sig, message: "merge")
            when "cherry-pick"
              repo.cherry_pick(source, committer: sig)
            else
              repo.rebase("main", committer: sig)
            end
            GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
            GitOracle.run(root, "status", "--porcelain").stdout.should eq(expected_status)
            File.read(File.join(root, relocated)).should eq(expected_file)
            case operation
            when "merge"       then repo.merge.abort
            when "cherry-pick" then repo.cherry_pick.abort
            else                    repo.rebase.abort(committer: sig)
            end
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
        end
      end
    end
  end
end

describe "Git conflict relocation collisions" do
  ["sha1", "sha256"].each do |format|
    [false, true].each do |tracked|
      it "preserves #{format} #{tracked ? "tracked" : "untracked"} relocation destinations and continues" do
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "node"), "base\n")
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          File.delete(File.join(root, "node"))
          Dir.mkdir(File.join(root, "node"))
          File.write(File.join(root, "node/child"), "child\n")
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "topic")
          GitOracle.run(root, "checkout", "-q", "main")
          File.write(File.join(root, "node"), "changed\n")
          File.write(File.join(root, "node~HEAD"), "preserve\n")
          GitOracle.run(root, "add", tracked ? "." : "node")
          GitOracle.run(root, "commit", "-qm", "ours")
          oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
          unless tracked
            oracle.exit_code.should eq(2)
            repo = Git::Repository.new(root)
            sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
            expect_raises(Git::Error, /untracked/) do
              repo.merge("topic", author: sig, committer: sig, message: "merge")
            end
            File.read(File.join(root, "node~HEAD")).should eq("preserve\n")
            File.read(File.join(root, "node")).should eq("changed\n")
            File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
            next
          end
          oracle.exit_code.should eq(1)
          expected = GitOracle.run(root, "ls-files", "-s").stdout
          GitOracle.run(root, "merge", "--abort")
          repo = Git::Repository.new(root)
          sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
          repo.merge("topic", author: sig, committer: sig, message: "merge").conflicts.should eq(["node~HEAD_0"])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected)
          File.read(File.join(root, "node~HEAD")).should eq("preserve\n")
          File.write(File.join(root, "unrelated"), "keep\n")
          GitOracle.run(root, "add", "unrelated")
          expect_raises(Git::Error, /unrelated staged/) { repo.merge.abort }
          GitOracle.run(root, "rm", "--cached", "unrelated")
          File.delete(File.join(root, "unrelated"))
          repo.merge.abort
          File.read(File.join(root, "node~HEAD")).should eq("preserve\n")
          File.exists?(File.join(root, "node~HEAD_0")).should be_false
          repo.merge("topic", author: sig, committer: sig, message: "merge")
          GitOracle.run(root, "add", "node", "node~HEAD_0")
          repo.merge.continue(author: sig, committer: sig)
          GitOracle.run(root, "ls-files", "-u").stdout.should eq("")
          GitOracle.run(root, "fsck", "--strict").success?.should be_true
        end
      end
    end
  end
end

describe "Git relocated merge content" do
  ["sha1", "sha256"].each do |format|
    ["merged-content", "deleted-destination"].each do |scenario|
      it "preserves #{format} #{scenario} index stages during relocation" do
        GitOracle.with_repo(format: format) do |root|
          original = (0...20).map { |i| "line #{i}: stable\n" }.join
          source_path = scenario == "merged-content" ? "old" : "node"
          File.write(File.join(root, source_path), original)
          File.write(File.join(root, "node~HEAD"), "reserved\n") if scenario == "deleted-destination"
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          if scenario == "merged-content"
            File.write(File.join(root, "old"), original.sub("line 15:", "remote edit:"))
          else
            GitOracle.run(root, "rm", "node", "node~HEAD")
          end
          Dir.mkdir(File.join(root, "node"))
          File.write(File.join(root, "node/child"), "child\n")
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "topic")
          GitOracle.run(root, "checkout", "-q", "main")
          GitOracle.run(root, "mv", "old", "node") if scenario == "merged-content"
          File.write(File.join(root, "node"), original.sub("line 2:", "local edit:"))
          GitOracle.run(root, "add", "-A")
          GitOracle.run(root, "commit", "-qm", "main")
          GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          path = scenario == "deleted-destination" ? "node~HEAD_0" : "node~HEAD"
          expected_content = File.read(File.join(root, path))
          GitOracle.run(root, "merge", "--abort")
          repo = Git::Repository.new(root)
          sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
          repo.merge("topic", author: sig, committer: sig, message: "merge").conflicts.should eq([path])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          File.read(File.join(root, path)).should eq(expected_content)
          repo.merge.abort
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
