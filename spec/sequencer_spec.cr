require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P32 native Git cherry-pick and revert sequencer" do
  ["sha1", "sha256"].each do |format|
    it "P32-O01 clean cherry-picks a #{format} commit preserving source author and message" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "picked"), "from topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "pick me", extra_env: {
          "GIT_AUTHOR_NAME" => "Source Author", "GIT_AUTHOR_EMAIL" => "source@example.test",
          "GIT_AUTHOR_DATE" => "@1234567000 +0230", "GIT_COMMITTER_DATE" => "@1234567001 +0000",
        })
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "local"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "local")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        committer = Git::Signature.new("Picker", "picker@example.test", 1234567999_i64, -300)
        result = repo.cherry_pick("topic", committer: committer)
        result.conflicts.should be_empty
        result.original_head.should eq(original)
        result.source.should eq(source)
        result.commit_oid.should_not be_nil
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split.should eq([result.commit_oid, original])
        GitOracle.run(root, "show", "-s", "--format=%an <%ae>|%at|%ai|%cn <%ce>|%ct|%s", "HEAD").stdout.strip.should eq(
          "Source Author <source@example.test>|1234567000|2009-02-14 01:46:40 +0230|Picker <picker@example.test>|1234567999|pick me")
        File.read(File.join(root, "picked")).should eq("from topic\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.sequencer_state?.should be_nil
      end
    end

    it "P32-O02 records #{format} cherry-pick conflicts, resolves and continues" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "pick conflict", extra_env: {
          "GIT_AUTHOR_NAME" => "Source", "GIT_AUTHOR_EMAIL" => "source@example.test",
          "GIT_AUTHOR_DATE" => "@1234500000 -0700",
        })
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        theirs_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        ours_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        repo = Git::Repository.new(root)
        committer = Git::Signature.new("Picker", "picker@example.test", 1234600000_i64, 0)
        result = repo.cherry_pick("topic", committer: committer)
        result.conflicts.should eq(["shared"])
        result.commit_oid.should be_nil
        File.read(File.join(root, ".git", "CHERRY_PICK_HEAD")).strip.should eq(source)
        File.exists?(File.join(root, ".git", "REVERT_HEAD")).should be_false
        repo.sequencer_conflicts.should eq([Git::Merge::Conflict.new("shared",
          Git::Checkout::FileState.new("100644", base_blob),
          Git::Checkout::FileState.new("100644", ours_blob),
          Git::Checkout::FileState.new("100644", theirs_blob))])
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.lines.size.should eq(3)
        File.write(File.join(root, "shared"), "resolved\n")
        repo.stage_file("shared")
        oid = repo.cherry_pick_continue(committer: committer)
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split.should eq([oid, original])
        GitOracle.run(root, "show", "-s", "--format=%an <%ae>|%s", "HEAD").stdout.strip.should eq("Source <source@example.test>|pick conflict")
        File.read(File.join(root, "shared")).should eq("resolved\n")
        repo.sequencer_state?.should be_nil
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O03 aborts a conflicted #{format} cherry-pick to the original tree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        File.write(File.join(root, "added"), "new\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick("topic", committer: sig).conflicts.should eq(["shared"])
        File.write(File.join(root, "shared"), "interim\n")
        repo.cherry_pick_abort.to_set.should eq(["added", "shared"].to_set)
        File.read(File.join(root, "shared")).should eq("ours\n")
        File.exists?(File.join(root, "added")).should be_false
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.sequencer_state?.should be_nil
      end
    end

    it "P32-O04 cleanly reverts a #{format} commit with Git-style message" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "changed\n")
        File.write(File.join(root, "added"), "new\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "change things")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "later"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "later")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        author = Git::Signature.new("Reverter", "reverter@example.test", 1234700000_i64, 60)
        committer = Git::Signature.new("Committer", "committer@example.test", 1234700001_i64, 60)
        result = repo.revert(source, author: author, committer: committer)
        result.conflicts.should be_empty
        result.commit_oid.should_not be_nil
        File.read(File.join(root, "f")).should eq("base\n")
        File.exists?(File.join(root, "added")).should be_false
        File.read(File.join(root, "later")).should eq("later\n")
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split.should eq([result.commit_oid, original])
        GitOracle.run(root, "show", "-s", "--format=%an <%ae>|%cn <%ce>|%B", "HEAD").stdout.should contain(
          "Reverter <reverter@example.test>|Committer <committer@example.test>|Revert \"change things\"")
        GitOracle.run(root, "show", "-s", "--format=%B", "HEAD").stdout.should contain("This reverts commit #{source}.")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O05 reverts a #{format} root commit to an empty tracked tree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "a\n")
        File.write(File.join(root, "b"), "b\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "root")
        root_commit = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.revert(root_commit, author: sig, committer: sig)
        result.conflicts.should be_empty
        File.exists?(File.join(root, "a")).should be_false
        File.exists?(File.join(root, "b")).should be_false
        GitOracle.run(root, "ls-tree", "-r", "--name-only", "HEAD").stdout.should eq("")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O06 requires and honors #{format} mainline selection for a merge commit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "side")
        File.write(File.join(root, "side"), "side\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "side")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main")
        GitOracle.run(root, "merge", "--no-ff", "-qm", "merge side", "side")
        merge = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "reset", "--hard", "-q", base)
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /mainline/) { repo.cherry_pick(merge, committer: sig) }
        repo.cherry_pick(merge, committer: sig, mainline: 1).conflicts.should be_empty
        File.exists?(File.join(root, "side")).should be_true
        File.exists?(File.join(root, "main")).should be_false
        GitOracle.run(root, "reset", "--hard", "-q", base)
        repo = Git::Repository.new(root)
        repo.cherry_pick(merge, committer: sig, mainline: 2).conflicts.should be_empty
        File.exists?(File.join(root, "main")).should be_true
        File.exists?(File.join(root, "side")).should be_false
      end
    end

    it "P32-O07 records #{format} revert conflicts and continues with the stored author" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        parent_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        File.write(File.join(root, "shared"), "source\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "source change")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        source_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        File.write(File.join(root, "shared"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "later")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        ours_blob = GitOracle.run(root, "rev-parse", "HEAD:shared").stdout.strip
        repo = Git::Repository.new(root)
        author = Git::Signature.new("Reverter", "reverter@example.test", 1234800000_i64, 0)
        committer = Git::Signature.new("Committer", "committer@example.test", 1234800001_i64, 0)
        result = repo.revert(source, author: author, committer: committer)
        result.conflicts.should eq(["shared"])
        File.read(File.join(root, ".git", "REVERT_HEAD")).strip.should eq(source)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
        repo.sequencer_conflicts.should eq([Git::Merge::Conflict.new("shared",
          Git::Checkout::FileState.new("100644", source_blob),
          Git::Checkout::FileState.new("100644", ours_blob),
          Git::Checkout::FileState.new("100644", parent_blob))])
        File.write(File.join(root, "shared"), "resolved revert\n")
        repo.stage_file("shared")
        oid = repo.revert_continue(committer: committer)
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split.should eq([oid, original])
        GitOracle.run(root, "show", "-s", "--format=%an <%ae>|%s", "HEAD").stdout.strip.should eq(
          "Reverter <reverter@example.test>|Revert \"source change\"")
        repo.sequencer_state?.should be_nil
      end
    end

    it "P32-O08 aborts a conflicted #{format} revert without losing later content" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "shared"), "source\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "source")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "shared"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "later")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.revert(source, author: sig, committer: sig).conflicts.should eq(["shared"])
        File.write(File.join(root, "shared"), "manual\n")
        repo.revert_abort.should eq(["shared"])
        File.read(File.join(root, "shared")).should eq("later\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O09 cherry-picks a #{format} root commit onto an existing history" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main root")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "--orphan", "orphan")
        GitOracle.run(root, "rm", "-rf", ".")
        File.write(File.join(root, "root-added"), "root\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "orphan root", extra_env: {
          "GIT_AUTHOR_NAME" => "Root Author", "GIT_AUTHOR_EMAIL" => "root@example.test",
          "GIT_AUTHOR_DATE" => "@1234900000 +0000",
        })
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("Picker", "picker@example.test", 1234900001_i64, 0)
        result = repo.cherry_pick(source, committer: sig)
        result.parent.should be_nil
        File.read(File.join(root, "main")).should eq("main\n")
        File.read(File.join(root, "root-added")).should eq("root\n")
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.strip.split.should eq([result.commit_oid, original])
        GitOracle.run(root, "show", "-s", "--format=%an <%ae>", "HEAD").stdout.strip.should eq("Root Author <root@example.test>")
      end
    end

    it "P32-O10 leaves #{format} empty replay state for skip and supports allow_empty" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "commit", "--allow-empty", "-qm", "empty")
        empty = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "reset", "--hard", "-q", base)
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Sequencer::EmptyResult) { repo.cherry_pick(empty, committer: sig) }
        repo.sequencer_state?.should_not be_nil
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(base)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.sequencer_skip.should be_empty
        repo.sequencer_state?.should be_nil
        result = repo.cherry_pick(empty, committer: sig, allow_empty: true)
        result.commit_oid.should_not be_nil
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(GitOracle.run(root, "rev-parse", "#{base}^{tree}").stdout.strip)
      end
    end

    it "P32-O11 preserves #{format} v4 conflict stages for Git readers" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        GitOracle.run(root, "update-index", "--index-version", "4")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick("topic", committer: sig).conflicts.should eq(["shared"])
        GitOracle.run(root, "ls-files", "--stage", "shared").stdout.lines.size.should eq(3)
        repo.cherry_pick_abort
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O12 blocks unrelated history mutations during a #{format} sequencer conflict" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick("topic", committer: sig).conflicts.should eq(["shared"])
        expect_raises(Git::Error, /sequencer/) { repo.reset_head(mode: Git::Reset::Mode::Mixed) }
        expect_raises(Git::Error, /sequencer/) { repo.checkout_branch("topic") }
        expect_raises(Git::Error, /sequencer/) { repo.commit_staged(author: sig, committer: sig, message: "bad") }
        expect_raises(Git::Error, /sequencer/) { repo.merge_three_way("topic", author: sig, committer: sig, message: "bad") }
        expect_raises(Git::Error, /already in progress/) { repo.cherry_pick("topic", committer: sig) }
        repo.cherry_pick_abort
      end
    end

    it "P32-O13 matches Git for a clean #{format} file-to-directory cherry-pick" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "path"), "old\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        GitOracle.run(root, "rm", "-q", "path")
        Dir.mkdir(File.join(root, "path"))
        File.write(File.join(root, "path", "child"), "new\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "file to dir")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "local"), "local\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "local")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "cherry-pick", source)
        expected_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        GitOracle.run(root, "reset", "--hard", "-q", original)
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick(source, committer: sig).conflicts.should be_empty
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(expected_tree)
        File.read(File.join(root, "path", "child")).should eq("new\n")
      end
    end

    it "P32-O14 matches Git for a clean #{format} mainline revert of a merge" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "side")
        File.write(File.join(root, "side"), "side\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "side")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main")
        GitOracle.run(root, "merge", "--no-ff", "-qm", "merge side", "side")
        merge = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "later"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "later")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "revert", "-m", "1", "--no-edit", merge)
        expected_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        GitOracle.run(root, "reset", "--hard", "-q", original)
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.revert(merge, author: sig, committer: sig, mainline: 1).conflicts.should be_empty
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(expected_tree)
        File.exists?(File.join(root, "side")).should be_false
        File.exists?(File.join(root, "main")).should be_true
        File.exists?(File.join(root, "later")).should be_true
      end
    end

    it "P32-O15 refuses a foreign #{format} index lock without sequencer metadata" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "picked"), "picked\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error) { repo.cherry_pick("topic", committer: sig) }
        File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
        File.exists?(File.join(root, ".git", "CRYSTAL_SEQUENCER_ORIG")).should be_false
      end
    end

    it "P32-O16 refuses unrelated staged #{format} paths during abort" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick("topic", committer: sig).conflicts.should eq(["shared"])
        File.write(File.join(root, "unrelated"), "keep\n")
        repo.stage_file("unrelated")
        expect_raises(Git::Error, /unrelated staged/) { repo.cherry_pick_abort }
        repo.sequencer_state?.should_not be_nil
        File.read(File.join(root, "unrelated")).should eq("keep\n")
        repo.remove_from_index("unrelated")
        File.delete(File.join(root, "unrelated"))
        repo.cherry_pick_abort
      end
    end

    it "P32-O17 leaves abortable #{format} state after injected post-metadata failure" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "picked"), "picked\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        injected = false
        check = -> do
          if !injected && File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD"))
            injected = true
            raise Git::Error.new("injected sequencer failure")
          end
        end
        error = expect_raises(Git::Sequencer::PartialPublication) do
          repo.cherry_pick("topic", committer: sig, check: check)
        end
        error.changed_paths.should be_empty
        error.index_published.should be_false
        repo.sequencer_state?.should_not be_nil
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        repo.cherry_pick_abort
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P32-O18 refuses dirty and staged #{format} inputs before state publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "picked"), "picked\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "base"), "dirty\n")
        expect_raises(Git::Error, /dirty/) { repo.cherry_pick("topic", committer: sig) }
        repo.sequencer_state?.should be_nil
        GitOracle.run(root, "checkout", "--", "base")
        File.write(File.join(root, "staged"), "staged\n")
        GitOracle.run(root, "add", "staged")
        expect_raises(Git::Error, /index equal to HEAD/) { repo.cherry_pick("topic", committer: sig) }
        repo.sequencer_state?.should be_nil
      end
    end

    it "P32-O19 cherry-picks a #{format} symlink retarget without dereferencing it" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "target-a"), "A\n")
        File.write(File.join(root, "target-b"), "B\n")
        File.symlink("target-a", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "link"))
        File.symlink("target-b", File.join(root, "link"))
        GitOracle.run(root, "add", "link")
        GitOracle.run(root, "commit", "-qm", "retarget")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "local"), "local\n")
        GitOracle.run(root, "add", "local")
        GitOracle.run(root, "commit", "-qm", "local")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.cherry_pick(source, committer: sig).conflicts.should be_empty
        File.symlink?(File.join(root, "link")).should be_true
        File.readlink(File.join(root, "link")).should eq("target-b")
        File.read(File.join(root, "target-a")).should eq("A\n")
        File.read(File.join(root, "target-b")).should eq("B\n")
      end
    end

    it "P32-O20 restores a #{format} D/F replay on abort when another path conflicts" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "path"), "old\n")
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        GitOracle.run(root, "rm", "-q", "path")
        Dir.mkdir(File.join(root, "path"))
        File.write(File.join(root, "path", "child"), "new\n")
        File.write(File.join(root, "shared"), "theirs\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "ours\n")
        GitOracle.run(root, "add", "shared")
        GitOracle.run(root, "commit", "-qm", "ours")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.cherry_pick("topic", committer: sig)
        result.conflicts.should eq(["shared"])
        File.directory?(File.join(root, "path")).should be_true
        File.read(File.join(root, "path", "child")).should eq("new\n")
        repo.cherry_pick_abort
        File.file?(File.join(root, "path")).should be_true
        File.read(File.join(root, "path")).should eq("old\n")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
