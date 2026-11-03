require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P29 native Git three-way merge and recovery" do
  ["sha1", "sha256"].each do |format|
    it "P29-O01 merges disjoint #{format} paths into a real two-parent commit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "same"), "unchanged\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        topic = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        previous = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "Merge topic\n")
        result.ours.should eq(previous)
        result.theirs.should eq(topic)
        result.base.should eq(base)
        result.conflicts.should be_empty
        result.changed_paths.should eq(["topic"])
        result.commit_oid.should_not be_nil
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split(' ').should eq([result.commit_oid, previous, topic])
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.read(File.join(root, "main")).should eq("ours\n")
        File.read(File.join(root, "topic")).should eq("theirs\n")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end

    it "P29-O02 records #{format} conflict stages, resolves and continues" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        File.write(File.join(root, "unchanged"), "old\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        base_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        theirs = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        their_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        ours = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        our_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "Merge topic\n")
        result.conflicts.should eq(["shared"])
        repo.merge_conflicts.should eq([Git::Merge::Conflict.new("shared",
          Git::Checkout::FileState.new("100644", base_blob),
          Git::Checkout::FileState.new("100644", our_blob),
          Git::Checkout::FileState.new("100644", their_blob))])
        result.commit_oid.should be_nil
        result.changed_paths.should eq(["shared"])
        repo.head[1].should eq(ours)
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.lines.map(&.strip).should eq([
          "100644 #{base_blob} 1\tshared", "100644 #{our_blob} 2\tshared", "100644 #{their_blob} 3\tshared",
        ])
        File.read(File.join(root, "shared")).should eq("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic\n")
        repo.merge_state?.should eq({"refs/heads/main", ours, theirs})
        expect_raises(Git::Error, /unresolved/) { repo.merge_continue(author: sig, committer: sig) }
        File.write(File.join(root, "shared"), "resolved\n")
        repo.stage_file("shared")
        commit = repo.merge_continue(author: sig, committer: sig)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(commit)
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split(' ').should eq([commit, ours, theirs])
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
        repo.merge_state?.should be_nil
        GitOracle.run(root, "merge-base", "HEAD^1", "HEAD^2").stdout.strip.should eq(base)
      end
    end

    it "P29-O03 aborts a conflicted #{format} merge after working-copy edits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        File.write(File.join(root, "extra"), "new\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        ours = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.merge_three_way("topic", author: sig, committer: sig, message: "Merge topic\n").conflicts.should eq(["shared"])
        File.write(File.join(root, "shared"), "interim\n")
        repo.merge_abort.to_set.should eq(["shared", "extra"].to_set)
        File.read(File.join(root, "shared")).should eq("ours\n")
        File.exists?(File.join(root, "extra")).should be_false
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
        repo.merge_state?.should be_nil
      end
    end

    it "P29-O04 refuses #{format} dirty worktree and foreign lock without mutation" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "main"), "dirty\n")
        expect_raises(Git::Error, /dirty/) { repo.merge_three_way("topic", author: sig, committer: sig, message: "m") }
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
        GitOracle.run(root, "checkout", "--", "main")
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        expect_raises(Git::Error) { repo.merge_three_way("topic", author: sig, committer: sig, message: "m") }
        File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end

    it "P29-O05 combines independent #{format} text line edits without conflict" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "one\ntwo\nthree\nfour\nfive\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "one\ntwo\nthree\nfour\nFIVE\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ONE\ntwo\nthree\nfour\nfive\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        expected = "ONE\ntwo\nthree\nfour\nFIVE\n"
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        result.changed_paths.should eq(["shared"])
        result.commit_oid.should_not be_nil
        File.read(File.join(root, "shared")).should eq(expected)
        GitOracle.run(root, "show", "HEAD:shared").stdout.should eq(expected)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P29-O06 preserves #{format} delete/modify conflict stage omissions" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        GitOracle.run(root, "rm", "-q", "shared")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should eq(["shared"])
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.lines.size.should eq(2)
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.should contain(" 1\tshared")
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.should contain(" 3\tshared")
        File.read(File.join(root, "shared")).should eq("theirs\n")
        repo.merge_abort
        File.exists?(File.join(root, "shared")).should be_false
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P29-O07 rejects #{format} second merge while one is unresolved" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        expect_raises(Git::Error, /in-progress merge/) { repo.reset_head(mode: Git::Reset::Mode::Mixed) }
        expect_raises(Git::Error, /in-progress merge/) { repo.checkout_branch("topic") }
        expect_raises(Git::Error, /in-progress merge/) { repo.commit_staged(author: sig, committer: sig, message: "bad") }
        expect_raises(Git::Error, /already in progress/) do
          repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        end
        repo.merge_abort
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end

    it "P29-O08 preserves #{format} v4 conflict stages for the standard Git reader" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        GitOracle.run(root, "update-index", "--index-version", "4")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.merge_three_way("topic", author: sig, committer: sig, message: "merge").conflicts.should eq(["shared"])
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.lines.size.should eq(3)
        File.open(File.join(root, ".git", "index")) do |io|
          io.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(0x44495243_u32)
          io.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(4_u32)
        end
        repo.merge_abort
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P29-O09 retains #{format} metadata after injected publication failure" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "new"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "old"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        injected = -> do
          raise Git::Error.new("injected failure") if File.exists?(File.join(root, ".git", "MERGE_HEAD"))
        end
        expect_raises(Git::Merge::PartialPublication, /partially published/) do
          repo.merge_three_way("topic", author: sig, committer: sig, message: "merge", check: injected)
        end
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
        repo.merge_state?.should_not be_nil
        repo.merge_abort.should be_empty
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.merge_state?.should be_nil
      end
    end

    it "P29-O10 refuses #{format} unrelated staged paths when aborting" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        File.write(File.join(root, "user-added"), "keep\n")
        repo.stage_file("user-added")
        expect_raises(Git::Error, /unrelated staged/) { repo.merge_abort }
        File.read(File.join(root, "user-added")).should eq("keep\n")
        repo.remove_from_index("user-added")
        repo.merge_abort
        File.read(File.join(root, "user-added")).should eq("keep\n")
        repo.merge_state?.should be_nil
      end
    end

    it "P29-O11 blocks #{format} foreign merge metadata symlinks" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "old"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "new"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "old"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        admin = File.join(root, ".git")
        File.write(File.join(root, "private"), "private\n")
        File.symlink(File.join(root, "private"), File.join(admin, "MERGE_HEAD"))
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error) do
          repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        end
        File.read(File.join(root, "private")).should eq("private\n")
        File.symlink?(File.join(admin, "MERGE_HEAD")).should be_true
      end
    end

    it "P29-O12 matches upstream Git's #{format} clean text merge worktree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), (1..20).map { |i| "line #{i}\n" }.join)
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        lines = File.read_lines(File.join(root, "shared"))
        lines[16] = "topic edit"
        File.write(File.join(root, "shared"), lines.join("\n") + "\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        lines = File.read_lines(File.join(root, "shared"))
        lines[2] = "main edit"
        File.write(File.join(root, "shared"), lines.join("\n") + "\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main")
        oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
        oracle.exit_code.should eq(0)
        expected = File.read(File.join(root, "shared"))
        GitOracle.run(root, "merge", "--abort")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.read(File.join(root, "shared")).should eq(expected)
        GitOracle.run(root, "show", "HEAD:shared").stdout.should eq(expected)
      end
    end
  end
end
