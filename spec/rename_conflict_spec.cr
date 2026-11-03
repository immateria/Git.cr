require "spec"
require "../src/git"
require "./support/git_oracle"

# Git 2.47.3 is the compatibility oracle for the exact-rename conflict
# layout, including preservation of the rename target in the worktree.
describe "rename/delete and rename/type conflicts" do
  sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      ["merge", "cherry-pick"].each do |operation|
        it "M2 #{format} #{operation} rename_ours=#{rename_ours}" do
          GitOracle.with_repo(format: format) do |root|
            File.write(File.join(root, "old"), "original\n")
            File.write(File.join(root, "keep"), "keep\n")
            GitOracle.run(root, "add", ".")
            GitOracle.run(root, "commit", "-qm", "base")
            GitOracle.run(root, "checkout", "-qb", "topic")
            if operation == "cherry-pick"
              # Incoming commit carries the opposite change against base.
              if rename_ours
                GitOracle.run(root, "rm", "-q", "old")
              else
                GitOracle.run(root, "mv", "old", "new")
              end
            elsif rename_ours
              GitOracle.run(root, "rm", "-q", "old")
            else
              GitOracle.run(root, "mv", "old", "new")
            end
            GitOracle.run(root, "commit", "-qm", "topic")
            source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            GitOracle.run(root, "checkout", "-q", "main")
            if rename_ours
              GitOracle.run(root, "mv", "old", "new")
            else
              GitOracle.run(root, "rm", "-q", "old")
            end
            GitOracle.run(root, "commit", "-qm", "ours")
            original_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            oracle = if operation == "merge"
                       GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
                     else
                       GitOracle.run(root, "cherry-pick", source, check: false)
                     end
            oracle.exit_code.should eq(1)
            expected_index = GitOracle.run(root, "ls-files", "-s").stdout
            expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
            expected_file = File.read(File.join(root, "new"))
            GitOracle.run(root, operation == "merge" ? "merge" : "cherry-pick", "--abort")
            repo = Git::Repository.new(root)
            if operation == "merge"
              result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
              result.conflicts.should eq(["new"])
              repo.merge_conflicts.map(&.path).should eq(["new"])
            else
              result = repo.cherry_pick(source, committer: sig)
              result.conflicts.should eq(["new"])
              repo.sequencer_conflicts.map(&.path).should eq(["new"])
            end
            GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
            GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
            File.read(File.join(root, "new")).should eq(expected_file)
            if operation == "merge"
              repo.merge_abort
            else
              repo.cherry_pick_abort
            end
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original_head)
            GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("")

            # Resolve to a tree different from HEAD before continuing: when
            # HEAD already has the rename, accepting it unchanged would make
            # a cherry-pick empty (Git correctly requires skip in that case).
            if operation == "merge"
              repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
            else
              repo.cherry_pick(source, committer: sig)
            end
            if rename_ours
              GitOracle.run(root, "rm", "-q", "new")
            else
              GitOracle.run(root, "add", "new")
            end
            committed = if operation == "merge"
                          repo.merge_continue(author: sig, committer: sig)
                        else
                          repo.cherry_pick_continue(committer: sig)
                        end
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(committed)
            GitOracle.run(root, "ls-files", "-u").stdout.should eq("")
            GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("")
          end
        end
      end
    end

    [true, false].each do |rename_ours|
      it "D1 #{format} rename/type rename_ours=#{rename_ours}" do
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "old"), "original\n")
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          if rename_ours
            File.delete(File.join(root, "old"))
            File.symlink("destination", File.join(root, "old"))
            GitOracle.run(root, "add", "-A")
          else
            GitOracle.run(root, "mv", "old", "new")
          end
          GitOracle.run(root, "commit", "-qm", "topic")
          GitOracle.run(root, "checkout", "-q", "main")
          if rename_ours
            GitOracle.run(root, "mv", "old", "new")
          else
            File.delete(File.join(root, "old"))
            File.symlink("destination", File.join(root, "old"))
            GitOracle.run(root, "add", "-A")
          end
          GitOracle.run(root, "commit", "-qm", "ours")
          oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
          oracle.exit_code.should eq(1)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
          GitOracle.run(root, "merge", "--abort")
          repo = Git::Repository.new(root)
          result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
          result.conflicts.should eq(["new"])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
          File.symlink?(File.join(root, "old")).should be_true
          repo.merge_abort
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("")
        end
      end
    end
  end
end

describe "rename/delete sequencer recovery" do
  sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      it "M2 #{format} rebase rename_ours=#{rename_ours} conflicts and aborts" do
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "old"), "original\n")
          File.write(File.join(root, "keep"), "keep\n")
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          if rename_ours
            GitOracle.run(root, "rm", "-q", "old")
          else
            GitOracle.run(root, "mv", "old", "new")
          end
          GitOracle.run(root, "commit", "-qm", "topic")
          original_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
          GitOracle.run(root, "checkout", "-q", "main")
          if rename_ours
            GitOracle.run(root, "mv", "old", "new")
          else
            GitOracle.run(root, "rm", "-q", "old")
          end
          GitOracle.run(root, "commit", "-qm", "main")
          GitOracle.run(root, "checkout", "-q", "topic")
          oracle = GitOracle.run(root, "rebase", "main", check: false)
          oracle.exit_code.should eq(1)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
          GitOracle.run(root, "rebase", "--abort")
          repo = Git::Repository.new(root)
          result = repo.rebase("main", committer: sig)
          result.completed.should be_false
          result.conflicts.should eq(["new"])
          repo.sequencer_conflicts.map(&.path).should eq(["new"])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
          File.read(File.join(root, "new")).should eq("original\n")
          repo.rebase_abort(committer: sig)
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original_head)
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("")
        end
      end
    end

    [true, false].each do |rename_ours|
      it "M2 #{format} revert rename_ours=#{rename_ours} conflicts and aborts" do
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "keep"), "keep\n")
          unless rename_ours
            File.write(File.join(root, "new"), "original\n")
          end
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          if rename_ours
            File.write(File.join(root, "old"), "original\n")
            GitOracle.run(root, "add", ".")
          else
            GitOracle.run(root, "mv", "new", "old")
          end
          GitOracle.run(root, "commit", "-qm", "to revert")
          to_revert = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
          if rename_ours
            GitOracle.run(root, "mv", "old", "new")
          else
            GitOracle.run(root, "rm", "-q", "old")
          end
          GitOracle.run(root, "commit", "-qm", "ours")
          original_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
          oracle = GitOracle.run(root, "revert", "--no-edit", to_revert, check: false)
          oracle.exit_code.should eq(1)
          expected_index = GitOracle.run(root, "ls-files", "-s").stdout
          expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
          GitOracle.run(root, "revert", "--abort")
          repo = Git::Repository.new(root)
          result = repo.revert(to_revert, author: sig, committer: sig)
          result.conflicts.should eq(["new"])
          repo.sequencer_conflicts.map(&.path).should eq(["new"])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
          File.read(File.join(root, "new")).should eq("original\n")
          repo.revert_abort
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original_head)
          GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("")
        end
      end
    end
  end
end
