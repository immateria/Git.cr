require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P33 native Git linear multi-commit rebase" do
  ["sha1", "sha256"].each do |format|
    it "P33-O01 rebases two #{format} commits in order with Git tree/message parity" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "a"), "a\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic one", extra_env: {
          "GIT_AUTHOR_NAME" => "One", "GIT_AUTHOR_EMAIL" => "one@example.test", "GIT_AUTHOR_DATE" => "@1234500000 +0200",
        })
        File.write(File.join(root, "b"), "b\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic two", extra_env: {
          "GIT_AUTHOR_NAME" => "Two", "GIT_AUTHOR_EMAIL" => "two@example.test", "GIT_AUTHOR_DATE" => "@1234500100 -0300",
        })
        GitOracle.run(root, "branch", "oracle")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main advance")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip

        GitOracle.run(root, "checkout", "-q", "oracle")
        GitOracle.run(root, "rebase", "main", extra_env: {"GIT_COMMITTER_DATE" => "@1234600000 +0000"})
        oracle_tree = GitOracle.run(root, "rev-parse", "oracle^{tree}").stdout.strip
        oracle_log = GitOracle.run(root, "log", "--reverse", "--format=%s|%an <%ae>", "main..oracle").stdout

        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        committer = Git::Signature.new("Rebaser", "rebaser@example.test", 1234600000_i64, 0)
        result = repo.rebase("main", committer: committer)
        result.completed.should be_true
        result.total.should eq(2)
        result.next_index.should eq(2)
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(oracle_tree)
        GitOracle.run(root, "log", "--reverse", "--format=%s|%an <%ae>", "#{main}..HEAD").stdout.should eq(oracle_log)
        GitOracle.run(root, "rev-list", "--first-parent", "--count", "#{main}..HEAD").stdout.strip.should eq("2")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.rebase_state?.should be_nil
        repo.sequencer_state?.should be_nil
      end
    end

    it "P33-O02 stops a #{format} rebase at conflict and continue replays the remaining commit" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "shared"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "shared"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "conflicting pick")
        first = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "later"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "later pick")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "shared"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main advance")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "topic")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase("main", committer: sig)
        result.completed.should be_false
        result.conflicts.should eq(["shared"])
        result.next_index.should eq(0)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(main)
        File.read(File.join(root, ".git", "REBASE_HEAD")).strip.should eq(first)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
        state = repo.rebase_state?.not_nil!
        state.next_index.should eq(0)
        state.expected_head.should eq(main)
        repo.sequencer_state?.not_nil!.kind.rebase?.should be_true
        GitOracle.run(root, "ls-files", "-u").stdout.should_not eq("")

        File.write(File.join(root, "shared"), "resolved\n")
        repo.stage_file("shared")
        completed = repo.rebase_continue(committer: sig)
        completed.completed.should be_true
        completed.next_index.should eq(2)
        File.read(File.join(root, "shared")).should eq("resolved\n")
        File.read(File.join(root, "later")).should eq("later\n")
        GitOracle.run(root, "log", "--reverse", "--format=%s", "#{main}..HEAD").stdout.should eq("conflicting pick\nlater pick\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.rebase_state?.should be_nil
      end
    end

    it "P33-O03 skips a conflicted #{format} replay and continues later commits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "f"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "drop me")
        File.write(File.join(root, "g"), "keep\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "keep me")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "f"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "topic")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo.rebase("main", committer: sig).completed.should be_false
        result = repo.rebase_skip(committer: sig)
        result.completed.should be_true
        File.read(File.join(root, "f")).should eq("main\n")
        File.read(File.join(root, "g")).should eq("keep\n")
        GitOracle.run(root, "log", "--reverse", "--format=%s", "#{main}..HEAD").stdout.should eq("keep me\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P33-O04 aborts a #{format} rebase after an earlier commit was already rewritten" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "a"), "first\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "clean first")
        File.write(File.join(root, "f"), "topic conflict\n")
        GitOracle.run(root, "commit", "-qam", "conflict second")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        original_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "f"), "main conflict\n")
        GitOracle.run(root, "commit", "-qam", "main")
        GitOracle.run(root, "checkout", "-q", "topic")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase("main", committer: sig)
        result.completed.should be_false
        result.next_index.should eq(1)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should_not eq(original)
        repo.rebase_abort(committer: sig).should_not be_empty
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(original_tree)
        File.read(File.join(root, "f")).should eq("topic conflict\n")
        File.read(File.join(root, "a")).should eq("first\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        repo.rebase_state?.should be_nil
        repo.sequencer_state?.should be_nil
      end
    end

    it "P33-O05 fast-forwards a #{format} branch that is behind its upstream" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "branch", "topic")
        File.write(File.join(root, "later"), "later\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main later")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase("main", committer: sig)
        result.completed.should be_true
        result.total.should eq(0)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(main)
        File.read(File.join(root, "later")).should eq("later\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P33-O06 leaves an already based #{format} branch unchanged" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        upstream = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "a"), "a\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase(upstream, committer: sig)
        result.completed.should be_true
        result.total.should eq(0)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        repo.rebase_state?.should be_nil
      end
    end

    it "P33-O07 refuses #{format} merge commits before publishing rebase state" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "branch", "upstream")
        GitOracle.run(root, "checkout", "-qb", "side")
        File.write(File.join(root, "side"), "side\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "side")
        GitOracle.run(root, "checkout", "-qb", "topic", "upstream")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "merge", "--no-ff", "-qm", "merge side", "side")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /merge commits unsupported/) do
          repo.rebase("upstream", committer: sig, onto: "side")
        end
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        repo.rebase_state?.should be_nil
        File.exists?(File.join(root, ".git", "rebase-merge")).should be_false
      end
    end

    it "P33-O08 drops a #{format} replay that becomes empty by default and can keep it explicitly" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "same"), "same\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "same patch")
        GitOracle.run(root, "branch", "keep-topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "same"), "same\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "same upstream")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip

        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo.rebase("main", committer: sig).completed.should be_true
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(main)

        GitOracle.run(root, "checkout", "-q", "keep-topic")
        repo = Git::Repository.new(root)
        result = repo.rebase("main", committer: sig, keep_empty: true)
        result.completed.should be_true
        result.total.should eq(1)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should_not eq(main)
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(
          GitOracle.run(root, "rev-parse", "main^{tree}").stdout.strip)
        GitOracle.run(root, "rev-list", "--count", "main..HEAD").stdout.strip.should eq("1")
      end
    end

    it "P33-O09 supports explicit #{format} onto while selecting commits relative to upstream" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "branch", "upstream")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "one"), "one\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "one")
        File.write(File.join(root, "two"), "two\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "two")
        GitOracle.run(root, "checkout", "-qb", "newbase", "upstream")
        File.write(File.join(root, "newbase"), "newbase\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "new base")
        newbase = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "topic")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase("upstream", onto: "newbase", committer: sig)
        result.completed.should be_true
        GitOracle.run(root, "rev-list", "--first-parent", "--format=%s", "#{newbase}..HEAD").stdout.should contain("one")
        File.read(File.join(root, "newbase")).should eq("newbase\n")
        File.read(File.join(root, "one")).should eq("one\n")
        File.read(File.join(root, "two")).should eq("two\n")
      end
    end

    it "P33-O10 moves across #{format} symlink and file/directory upstream transitions safely" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "file\n")
        File.symlink("one", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.delete(File.join(root, "node"))
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "child"), "child\n")
        File.delete(File.join(root, "link"))
        File.symlink("two", File.join(root, "link"))
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "upstream transitions")
        GitOracle.run(root, "checkout", "-q", "topic")

        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        result = repo.rebase("main", committer: sig)
        result.completed.should be_true
        File.symlink?(File.join(root, "link")).should be_true
        File.readlink(File.join(root, "link")).should eq("two")
        File.read(File.join(root, "node", "child")).should eq("child\n")
        File.read(File.join(root, "topic")).should eq("topic\n")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P33-O11 refuses dirty and staged #{format} inputs before publishing rebase state" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        upstream = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "dirty\n")
        expect_raises(Git::Error, /dirty/) { repo.rebase(upstream, committer: sig) }
        repo.rebase_state?.should be_nil
        GitOracle.run(root, "checkout", "--", "f")
        File.write(File.join(root, "staged"), "staged\n")
        GitOracle.run(root, "add", "staged")
        expect_raises(Git::Error, /index equal to HEAD/) { repo.rebase(upstream, committer: sig) }
        repo.rebase_state?.should be_nil
      end
    end

    it "P33-O12 blocks unrelated #{format} history mutations while rebase is stopped" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "f"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "f"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo.rebase("main", committer: sig).completed.should be_false
        expect_raises(Git::Error, /rebase|sequencer/) { repo.reset_head(mode: Git::Reset::Mode::Mixed) }
        expect_raises(Git::Error, /rebase|sequencer/) { repo.checkout_branch("main") }
        expect_raises(Git::Error, /rebase|sequencer/) { repo.commit_staged(author: sig, committer: sig, message: "bad") }
        expect_raises(Git::Error, /rebase|sequencer/) { repo.merge_three_way("main", author: sig, committer: sig, message: "bad") }
        expect_raises(Git::Error, /progress|sequencer|rebase/) { repo.cherry_pick("main", committer: sig) }
        repo.rebase_abort(committer: sig)
      end
    end

    it "P33-O13 preserves a foreign #{format} index lock and clears unstarted rebase metadata" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "topic"), "topic\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main")
        GitOracle.run(root, "checkout", "-q", "topic")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error) { repo.rebase("main", committer: sig) }
        File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        repo.rebase_state?.should be_nil
        File.exists?(File.join(root, ".git", "rebase-merge")).should be_false
      end
    end

    it "P33-O14 refuses unrelated staged #{format} paths during rebase abort" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "f"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "topic")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "f"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo.rebase("main", committer: sig).completed.should be_false
        File.write(File.join(root, "unrelated"), "keep\n")
        repo.stage_file("unrelated")
        expect_raises(Git::Error, /unrelated staged/) { repo.rebase_abort(committer: sig) }
        repo.rebase_state?.should_not be_nil
        repo.sequencer_state?.should_not be_nil
        File.read(File.join(root, "unrelated")).should eq("keep\n")
        repo.remove_from_index("unrelated")
        File.delete(File.join(root, "unrelated"))
        repo.rebase_abort(committer: sig)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P33-O15 leaves abortable #{format} outer and item state after injected replay failure" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "base"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "picked"), "picked\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "topic")
        original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "main"), "main\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "main")
        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        injected = false
        check = -> do
          if !injected && File.exists?(File.join(root, ".git", "REBASE_HEAD"))
            injected = true
            raise Git::Error.new("injected rebase replay failure")
          end
        end
        expect_raises(Git::Sequencer::PartialPublication) do
          repo.rebase("main", committer: sig, check: check)
        end
        repo.rebase_state?.should_not be_nil
        repo.sequencer_state?.not_nil!.kind.rebase?.should be_true
        repo.rebase_abort(committer: sig)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P33-O16 preserves #{format} v4 index conflict stages for Git readers" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(File.join(root, "f"), "topic\n")
        GitOracle.run(root, "commit", "-qam", "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "f"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        GitOracle.run(root, "checkout", "-q", "topic")
        GitOracle.run(root, "update-index", "--index-version", "4")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo.rebase("main", committer: sig).completed.should be_false
        GitOracle.run(root, "ls-files", "--stage", "f").stdout.lines.size.should eq(3)
        repo.rebase_abort(committer: sig)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
