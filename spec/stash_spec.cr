require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P34 native Git stash" do
  ["sha1", "sha256"].each do |format|
    it "P34-O01 saves mixed tracked #{format} state in Git-compatible stash commits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        base_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        File.write(File.join(root, "f"), "staged\n")
        GitOracle.run(root, "add", "f")
        staged_blob = GitOracle.run(root, "rev-parse", ":f").stdout.strip
        File.write(File.join(root, "f"), "unstaged\n")
        File.write(File.join(root, "u"), "untracked\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Stasher", "stash@example.test", 1234567890_i64, -300)
        entry = repo.stash.push(actor: actor, message: "demo").not_nil!
        entry.base_oid.should eq(base)
        entry.position.should eq(0)
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", entry.oid).stdout.strip.split.should eq([entry.oid, base, entry.index_oid])
        GitOracle.run(root, "rev-parse", "#{entry.index_oid}^{tree}").stdout.strip.should_not eq(base_tree)
        GitOracle.run(root, "rev-parse", "#{entry.index_oid}:f").stdout.strip.should eq(staged_blob)
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("unstaged\n")
        GitOracle.run(root, "show", "#{entry.index_oid}:f").stdout.should eq("staged\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("?? u\n")
        File.read(File.join(root, "f")).should eq("base\n")
        File.read(File.join(root, "u")).should eq("untracked\n")
        repo.stash.list.map(&.oid).should eq([entry.oid])
        GitOracle.run(root, "stash", "list", "--format=%gd|%gs").stdout.should contain("stash@{0}|On main: demo")
      end
    end

    it "P34-O02 applies #{format} stash with Git default index semantics and --index restoration" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        base_blob = GitOracle.run(root, "rev-parse", "HEAD:f").stdout.strip
        File.write(File.join(root, "f"), "staged\n")
        GitOracle.run(root, "add", "f")
        staged_blob = GitOracle.run(root, "rev-parse", ":f").stdout.strip
        File.write(File.join(root, "f"), "unstaged\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, message: "mixed").should_not be_nil

        applied = repo.stash.apply(actor: actor)
        applied.conflicts.should be_empty
        applied.index_restored.should be_false
        File.read(File.join(root, "f")).should eq("unstaged\n")
        GitOracle.run(root, "rev-parse", ":f").stdout.strip.should eq(base_blob)
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(" M f\n")
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")

        indexed = repo.stash.apply(actor: actor, restore_index: true)
        indexed.conflicts.should be_empty
        indexed.index_restored.should be_true
        File.read(File.join(root, "f")).should eq("unstaged\n")
        GitOracle.run(root, "rev-parse", ":f").stdout.strip.should eq(staged_blob)
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("MM f\n")
      end
    end

    it "P34-O03 matches #{format} default apply staging for added and deleted tracked paths" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)

        File.write(File.join(root, "g"), "new\n")
        GitOracle.run(root, "add", "g")
        repo.stash.push(actor: actor, message: "add").should_not be_nil
        repo.stash.apply(actor: actor).conflicts.should be_empty
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("A  g\n")
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        File.delete(File.join(root, "g")) if File.exists?(File.join(root, "g"))
        repo.stash.drop(0)

        GitOracle.run(root, "rm", "-q", "f")
        repo.stash.push(actor: actor, message: "delete").should_not be_nil
        repo.stash.apply(actor: actor).conflicts.should be_empty
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(" D f\n")
      end
    end

    it "P34-O04 applies #{format} stash as a three-way delta and retains it on conflict" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "stashed\n")
        entry = repo.stash.push(actor: actor, message: "conflict").not_nil!
        File.write(File.join(root, "f"), "current\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "current")

        applied = repo.stash.apply(actor: actor)
        applied.conflicts.should eq(["f"])
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
        File.exists?(File.join(root, ".git", "CRYSTAL_SEQUENCER_ORIG")).should be_false
        GitOracle.run(root, "ls-files", "-u", "f").stdout.lines.size.should eq(3)
        File.read(File.join(root, "f")).should contain("<<<<<<< HEAD")
        File.read(File.join(root, "f")).should contain("stashed")
      end
    end

    it "P34-O05 cleanly pops a #{format} stash and preserves a conflicted pop" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "one\n")
        first = repo.stash.push(actor: actor, message: "one").not_nil!
        pop = repo.stash.pop(actor: actor)
        pop.dropped.should be_true
        pop.applied.conflicts.should be_empty
        repo.refs.resolve?("refs/stash").should be_nil
        File.exists?(File.join(root, ".git", "logs", "refs", "stash")).should be_false
        File.read(File.join(root, "f")).should eq("one\n")

        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        File.write(File.join(root, "f"), "two\n")
        second = repo.stash.push(actor: actor, message: "two").not_nil!
        File.write(File.join(root, "f"), "other\n")
        GitOracle.run(root, "commit", "-qam", "other")
        conflict = repo.stash.pop(actor: actor)
        conflict.dropped.should be_false
        conflict.applied.conflicts.should eq(["f"])
        repo.refs.resolve?("refs/stash").should eq(second.oid)
      end
    end

    it "P34-O06 lists and middle-drops a #{format} stash stack with Git-readable reflog" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        ids = [] of String
        {"s1", "s2", "s3"}.each_with_index do |message, index|
          File.write(File.join(root, "f"), "#{index + 1}\n")
          ids << repo.stash.push(actor: actor, message: message).not_nil!.oid
        end
        repo.stash.list.map(&.oid).should eq(ids.reverse)
        dropped = repo.stash.drop(1)
        dropped.oid.should eq(ids[1])
        repo.stash.list.map(&.oid).should eq([ids[2], ids[0]])
        repo.refs.resolve?("refs/stash").should eq(ids[2])
        GitOracle.run(root, "stash", "list", "--format=%H|%gs").stdout.lines.map(&.strip).should eq([
          "#{ids[2]}|On main: s3",
          "#{ids[0]}|On main: s1",
        ])
      end
    end

    it "P34-O07 stashes and reapplies #{format} symlink target changes without following them" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "target-a"), "A\n")
        File.write(File.join(root, "target-b"), "B\n")
        File.symlink("target-a", File.join(root, "link"))
        GitOracle.run(root, "add", "target-a", "target-b", "link")
        GitOracle.run(root, "commit", "-qm", "base")
        File.delete(File.join(root, "link"))
        File.symlink("target-b", File.join(root, "link"))
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, message: "link").should_not be_nil
        File.readlink(File.join(root, "link")).should eq("target-a")
        repo.stash.apply(actor: actor).conflicts.should be_empty
        File.readlink(File.join(root, "link")).should eq("target-b")
        File.read(File.join(root, "target-b")).should eq("B\n")
      end
    end

    it "P34-O08 refuses unsafe #{format} excluded staged-deletion edits rather than losing bytes" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "rm", "--cached", "-q", "f")
        File.write(File.join(root, "f"), "untracked-but-important\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /excluded by staged deletion/) do
          repo.stash.push(actor: actor, message: "unsafe")
        end
        File.read(File.join(root, "f")).should eq("untracked-but-important\n")
        repo.refs.resolve?("refs/stash").should be_nil
      end
    end

    it "P34-O09 refuses a foreign #{format} index lock before publishing refs/stash" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "dirty\n")
        File.write(File.join(root, ".git", "index.lock"), "foreign")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /index.lock|descriptor file unavailable/) do
          repo.stash.push(actor: actor, message: "locked")
        end
        File.read(File.join(root, ".git", "index.lock")).should eq("foreign")
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "f")).should eq("dirty\n")
      end
    end

    it "P35-O01 applies #{format} Git-created -u stashes including untracked files" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "dirty\n")
        File.write(File.join(root, "u"), "untracked\n")
        GitOracle.run(root, "stash", "push", "-qu", "-m", "external")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.show
        entry.untracked_oid.should_not be_nil
        applied = repo.stash.apply(actor: actor)
        applied.conflicts.should be_empty
        File.read(File.join(root, "f")).should eq("dirty\n")
        File.read(File.join(root, "u")).should eq("untracked\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq(" M f\n?? u\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "P34-O11 returns nil for clean #{format} tracked state without creating a stash ref" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor).should be_nil
        repo.refs.resolve?("refs/stash").should be_nil
        repo.stash.list.should be_empty
      end
    end

    it "P34-O12 round-trips a staged #{format} file-to-directory transition" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "node"), "base\n")
        GitOracle.run(root, "add", "node")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "rm", "-q", "node")
        Dir.mkdir(File.join(root, "node"))
        File.write(File.join(root, "node", "leaf"), "leaf\n")
        GitOracle.run(root, "add", "node/leaf")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, message: "df").should_not be_nil
        File.file?(File.join(root, "node")).should be_true
        File.read(File.join(root, "node")).should eq("base\n")
        repo.stash.apply(actor: actor, restore_index: true).conflicts.should be_empty
        Dir.exists?(File.join(root, "node")).should be_true
        File.read(File.join(root, "node", "leaf")).should eq("leaf\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("D  node\nA  node/leaf\n")
      end
    end

    it "P34-O13 drops the top #{format} stash by moving refs/stash and rewriting its reflog" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "one\n")
        one = repo.stash.push(actor: actor, message: "one").not_nil!
        File.write(File.join(root, "f"), "two\n")
        two = repo.stash.push(actor: actor, message: "two").not_nil!
        repo.refs.resolve?("refs/stash").should eq(two.oid)
        repo.stash.drop(0).oid.should eq(two.oid)
        repo.refs.resolve?("refs/stash").should eq(one.oid)
        repo.stash.list.map(&.oid).should eq([one.oid])
        GitOracle.run(root, "stash", "list", "--format=%H|%gs").stdout.strip.should eq("#{one.oid}|On main: one")
      end
    end

    it "P34-O14 reports a durable #{format} stash when cleanup is interrupted after ref publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "dirty\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        injected = false
        check = -> do
          if !injected && repo.refs.resolve?("refs/stash")
            injected = true
            raise "injected stash cleanup failure"
          end
        end
        error = expect_raises(Git::Stash::PartialSave) do
          repo.stash.push(actor: actor, message: "recoverable", check: check)
        end
        injected.should be_true
        repo.refs.resolve?("refs/stash").should eq(error.stash_oid)
        repo.stash.show.oid.should eq(error.stash_oid)
        File.read(File.join(root, "f")).should eq("dirty\n")
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        repo.stash.apply(actor: actor).conflicts.should be_empty
        File.read(File.join(root, "f")).should eq("dirty\n")
      end
    end

    it "P34-O15 matches upstream Git for clean descendant #{format} stash application" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "stashed\n")
        repo.stash.push(actor: actor, message: "oracle").should_not be_nil
        File.write(File.join(root, "g"), "current\n")
        GitOracle.run(root, "add", "g")
        GitOracle.run(root, "commit", "-qm", "current")

        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        oracle_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
        oracle_index = GitOracle.run(root, "write-tree").stdout.strip
        oracle_f = File.read(File.join(root, "f"))
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")

        native = repo.stash.apply(actor: actor)
        native.conflicts.should be_empty
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(oracle_status)
        GitOracle.run(root, "write-tree").stdout.strip.should eq(oracle_index)
        File.read(File.join(root, "f")).should eq(oracle_f)
      end
    end

    it "P34-O16 refuses #{format} --index application on a different HEAD before worktree mutation" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        File.write(File.join(root, "f"), "stashed\n")
        repo.stash.push(actor: actor, message: "index-base").should_not be_nil
        File.write(File.join(root, "g"), "advance\n")
        GitOracle.run(root, "add", "g")
        GitOracle.run(root, "commit", "-qm", "advance")
        before = GitOracle.run(root, "status", "--porcelain=v1").stdout
        expect_raises(Git::Error, /original base HEAD/) do
          repo.stash.apply(actor: actor, restore_index: true)
        end
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(before)
        File.read(File.join(root, "g")).should eq("advance\n")
      end
    end

    it "P35-O02 writes Git-compatible #{format} -u stash parents and preserves ignored files" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        File.write(File.join(root, ".gitignore"), "*.ign\n")
        GitOracle.run(root, "add", "f", ".gitignore")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "f"), "dirty\n")
        File.write(File.join(root, "u"), "untracked\n")
        File.chmod(File.join(root, "u"), 0o755)
        File.symlink("u", File.join(root, "link"))
        File.write(File.join(root, "keep.ign"), "ignored\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("Stasher", "stash@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "untracked", include_untracked: true).not_nil!
        untracked = entry.untracked_oid.not_nil!
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", entry.oid).stdout.strip.split.should eq([
          entry.oid, base, entry.index_oid, untracked,
        ])
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", untracked).stdout.strip.split.should eq([untracked])
        GitOracle.run(root, "ls-tree", "-r", untracked).stdout.should contain("120000 blob")
        GitOracle.run(root, "ls-tree", "-r", untracked).stdout.should contain("100755 blob")
        GitOracle.run(root, "show", "#{untracked}:u").stdout.should eq("untracked\n")
        GitOracle.run(root, "show", "#{untracked}:link").stdout.should eq("u")
        File.read(File.join(root, "f")).should eq("base\n")
        File.exists?(File.join(root, "u")).should be_false
        File.symlink?(File.join(root, "link")).should be_false
        File.read(File.join(root, "keep.ign")).should eq("ignored\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should be_empty
      end
    end

    it "P35-O03 produces #{format} -u stashes that upstream Git can apply" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "dirty\n")
        File.write(File.join(root, "u"), "untracked\n")
        File.chmod(File.join(root, "u"), 0o755)
        File.symlink("u", File.join(root, "link"))
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "git-readable", include_untracked: true).not_nil!

        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        File.read(File.join(root, "f")).should eq("dirty\n")
        File.read(File.join(root, "u")).should eq("untracked\n")
        (File.info(File.join(root, "u")).permissions.value & 0o111).should_not eq(0)
        File.readlink(File.join(root, "link")).should eq("u")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq(" M f\n?? link\n?? u\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "P35-O04 saves and pops a #{format} untracked-only stash" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "u"), "only-untracked\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, include_untracked: true).not_nil!
        entry.untracked_oid.should_not be_nil
        File.exists?(File.join(root, "u")).should be_false
        pop = repo.stash.pop(actor: actor)
        pop.dropped.should be_true
        pop.applied.conflicts.should be_empty
        File.read(File.join(root, "u")).should eq("only-untracked\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq("?? u\n")
        repo.refs.resolve?("refs/stash").should be_nil
      end
    end

    it "P35-O05 reports #{format} untracked restore collisions without overwriting them" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "stashed\n")
        File.write(File.join(root, "u"), "saved\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "collision", include_untracked: true).not_nil!
        File.write(File.join(root, "u"), "current\n")

        error = expect_raises(Git::Stash::PartialApply) do
          repo.stash.apply(actor: actor)
        end
        error.stash_oid.should eq(entry.oid)
        error.changed_paths.should contain("f")
        File.read(File.join(root, "f")).should eq("stashed\n")
        File.read(File.join(root, "u")).should eq("current\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
      end
    end

    it "P35-O06 captures a modified staged-deletion #{format} path before cleanup" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "rm", "--cached", "-q", "f")
        File.write(File.join(root, "f"), "important\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "staged-delete", include_untracked: true).not_nil!
        untracked = entry.untracked_oid.not_nil!
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("important\n")
        GitOracle.run(root, "show", "#{untracked}:f").stdout.should eq("important\n")
        File.read(File.join(root, "f")).should eq("base\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should be_empty
      end
    end

    it "P35-O07 restores #{format} untracked files even when tracked replay conflicts" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "stashed\n")
        File.write(File.join(root, "u"), "untracked\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "conflict-u", include_untracked: true).not_nil!
        File.write(File.join(root, "f"), "current\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "current")

        applied = repo.stash.apply(actor: actor)
        applied.conflicts.should eq(["f"])
        File.read(File.join(root, "u")).should eq("untracked\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should contain("UU f\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should contain("?? u\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
      end
    end

    it "P36-O01 applies upstream Git #{format} -a stashes including ignored leaves" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, ".gitignore"), "ignored/\n*.log\n")
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".gitignore", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "dirty\n")
        File.write(File.join(root, "u"), "untracked\n")
        Dir.mkdir(File.join(root, "ignored"))
        File.write(File.join(root, "ignored", "x"), "ignored-dir\n")
        File.write(File.join(root, "trace.log"), "ignored-log\n")
        GitOracle.run(root, "stash", "push", "-a", "-m", "all")

        repo = Git::Repository.new(root)
        entry = repo.stash.show
        entry.untracked_oid.should_not be_nil
        applied = repo.stash.apply(actor: Git::Signature.new("S", "s@example.test", 1234567890_i64, 0))
        applied.conflicts.should be_empty
        File.read(File.join(root, "f")).should eq("dirty\n")
        File.read(File.join(root, "u")).should eq("untracked\n")
        File.read(File.join(root, "ignored", "x")).should eq("ignored-dir\n")
        File.read(File.join(root, "trace.log")).should eq("ignored-log\n")
        status = GitOracle.run(root, "status", "--porcelain=v1", "--ignored", "--untracked-files=all").stdout
        status.should contain(" M f\n")
        status.should contain("?? u\n")
        status.should contain("!! ignored/x\n")
        status.should contain("!! trace.log\n")
      end
    end

    it "P36-O02 writes Git-readable #{format} -a stashes and bypasses ignore filters" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, ".gitignore"), "ignored/\n*.log\n")
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", ".gitignore", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        Dir.mkdir_p(File.join(root, ".git", "info"))
        File.write(File.join(root, ".git", "info", "exclude"), "info.ign\n")
        File.write(File.join(root, "u"), "untracked\n")
        Dir.mkdir(File.join(root, "ignored"))
        File.write(File.join(root, "ignored", "x"), "ignored-dir\n")
        File.write(File.join(root, "trace.log"), "ignored-log\n")
        File.write(File.join(root, "info.ign"), "info-excluded\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "all", include_ignored: true).not_nil!
        untracked = entry.untracked_oid.not_nil!
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", entry.oid).stdout.strip.split.size.should eq(4)
        GitOracle.run(root, "rev-list", "--parents", "-n", "1", untracked).stdout.strip.split.should eq([untracked])
        GitOracle.run(root, "show", "#{untracked}:u").stdout.should eq("untracked\n")
        GitOracle.run(root, "show", "#{untracked}:ignored/x").stdout.should eq("ignored-dir\n")
        GitOracle.run(root, "show", "#{untracked}:trace.log").stdout.should eq("ignored-log\n")
        GitOracle.run(root, "show", "#{untracked}:info.ign").stdout.should eq("info-excluded\n")
        File.exists?(File.join(root, "u")).should be_false
        File.exists?(File.join(root, "ignored", "x")).should be_false
        File.exists?(File.join(root, "trace.log")).should be_false
        File.exists?(File.join(root, "info.ign")).should be_false

        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        File.read(File.join(root, "u")).should eq("untracked\n")
        File.read(File.join(root, "ignored", "x")).should eq("ignored-dir\n")
        File.read(File.join(root, "trace.log")).should eq("ignored-log\n")
        File.read(File.join(root, "info.ign")).should eq("info-excluded\n")
      end
    end

    it "P36-O03 saves and pops a #{format} ignored-only stash" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, ".gitignore"), "*.tmp\n")
        GitOracle.run(root, "add", ".gitignore")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "only.tmp"), "ignored-only\n")
        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)

        entry = repo.stash.push(actor: actor, include_ignored: true).not_nil!
        entry.untracked_oid.should_not be_nil
        File.exists?(File.join(root, "only.tmp")).should be_false
        pop = repo.stash.pop(actor: actor)
        pop.dropped.should be_true
        pop.applied.conflicts.should be_empty
        File.read(File.join(root, "only.tmp")).should eq("ignored-only\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--ignored", "--untracked-files=all").stdout.should eq("!! only.tmp\n")
        repo.refs.resolve?("refs/stash").should be_nil
      end
    end

    it "P37-O01 preserves the staged #{format} index and cleans only unstaged tracked changes with keep_index" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base1\nbase2\n")
        File.write(File.join(root, "g"), "gbase\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "stage1\nbase2\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "stage1\nwork2\n")
        File.write(File.join(root, "g"), "gwork\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "keep", keep_index: true).not_nil!

        File.read(File.join(root, "f")).should eq("stage1\nbase2\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("stage1\nbase2\n")
        File.read(File.join(root, "g")).should eq("gbase\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq("M  f\n")
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("stage1\nwork2\n")
        GitOracle.run(root, "show", "#{entry.index_oid}:f").stdout.should eq("stage1\nbase2\n")

        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        File.read(File.join(root, "f")).should eq("stage1\nwork2\n")
        File.read(File.join(root, "g")).should eq("gwork\n")
      end
    end

    it "P37-O02 preserves staged #{format} additions and deletions with keep_index" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        File.write(File.join(root, "g"), "gbase\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.delete(File.join(root, "f"))
        File.write(File.join(root, "n"), "new\n")
        GitOracle.run(root, "add", "-A")
        File.write(File.join(root, "g"), "gwork\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, message: "keep-shape", keep_index: true).should_not be_nil

        File.exists?(File.join(root, "f")).should be_false
        File.read(File.join(root, "n")).should eq("new\n")
        GitOracle.run(root, "show", ":n").stdout.should eq("new\n")
        File.read(File.join(root, "g")).should eq("gbase\n")
        status = GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout
        status.should contain("D  f\n")
        status.should contain("A  n\n")
        status.should_not contain("g")
      end
    end

    it "P37-O03 combines #{format} keep_index with untracked capture without disturbing staged state" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        File.write(File.join(root, ".gitignore"), "*.ign\n")
        GitOracle.run(root, "add", "f", ".gitignore")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "staged\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "u"), "untracked\n")
        File.write(File.join(root, "keep.ign"), "ignored\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, include_untracked: true, keep_index: true).not_nil!

        entry.untracked_oid.should_not be_nil
        File.read(File.join(root, "f")).should eq("staged\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("staged\n")
        File.exists?(File.join(root, "u")).should be_false
        File.read(File.join(root, "keep.ign")).should eq("ignored\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq("M  f\n")
      end
    end

    it "P37-O04 creates a #{format} stash for staged-only state while leaving that state intact" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "staged\n")
        GitOracle.run(root, "add", "f")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, keep_index: true).not_nil!

        entry.tree.should eq(entry.index_tree)
        File.read(File.join(root, "f")).should eq("staged\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("staged\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq("M  f\n")
      end
    end

    it "P38-O01 stashes only the staged #{format} delta and preserves disjoint unstaged edits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base1\nbase2\n")
        File.write(File.join(root, "g"), "gbase\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "stage1\nbase2\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "g"), "gwork\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "staged", staged_only: true).not_nil!

        entry.tree.should eq(entry.index_tree)
        File.read(File.join(root, "f")).should eq("base1\nbase2\n")
        File.read(File.join(root, "g")).should eq("gwork\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("base1\nbase2\n")
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq(" M g\n")
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("stage1\nbase2\n")

        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        File.read(File.join(root, "f")).should eq("stage1\nbase2\n")
        File.read(File.join(root, "g")).should eq("gwork\n")
      end
    end

    it "P38-O02 removes a non-overlapping staged #{format} same-file delta while preserving the unstaged delta" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "a\nb\nc\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "A\nb\nc\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "A\nb\nC\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, staged_only: true).not_nil!

        entry.tree.should eq(entry.index_tree)
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("A\nb\nc\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("a\nb\nc\n")
        File.read(File.join(root, "f")).should eq("a\nb\nC\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(" M f\n")
      end
    end

    it "P38-O03 reverts staged #{format} additions and deletions while saving their index tree" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        File.write(File.join(root, "g"), "gbase\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.delete(File.join(root, "f"))
        File.write(File.join(root, "n"), "new\n")
        GitOracle.run(root, "add", "-A")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, staged_only: true).not_nil!

        entry.tree.should eq(entry.index_tree)
        File.read(File.join(root, "f")).should eq("base\n")
        File.exists?(File.join(root, "n")).should be_false
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should be_empty
        GitOracle.run(root, "show", "#{entry.oid}:n").stdout.should eq("new\n")
        GitOracle.run(root, "show", "#{entry.oid}:f", check: false).success?.should be_false
      end
    end

    it "P38-O04 composes #{format} staged-only cleanup with keep_index" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "a\nb\nc\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "A\nb\nc\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "A\nb\nC\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, staged_only: true, keep_index: true).not_nil!

        entry.tree.should eq(entry.index_tree)
        GitOracle.run(root, "show", ":f").stdout.should eq("A\nb\nc\n")
        File.read(File.join(root, "f")).should eq("a\nb\nC\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("MM f\n")
      end
    end

    it "P38-O05 rejects #{format} staged-only untracked/all capture combinations before publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "staged\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "u"), "untracked\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(ArgumentError) do
          repo.stash.push(actor: actor, staged_only: true, include_untracked: true)
        end
        expect_raises(ArgumentError) do
          repo.stash.push(actor: actor, staged_only: true, include_ignored: true)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "f")).should eq("staged\n")
        File.read(File.join(root, "u")).should eq("untracked\n")
      end
    end

    it "P38-O06 returns nil for #{format} staged-only save when only unstaged state exists" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "base\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "work\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, staged_only: true).should be_nil
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "f")).should eq("work\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(" M f\n")
      end
    end

    it "P38-O07 fails closed before ref publication for overlapping #{format} staged and unstaged edits" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "a\nb\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "A\nb\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "B\nb\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /staged-only cleanup conflict/) do
          repo.stash.push(actor: actor, staged_only: true)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        GitOracle.run(root, "show", ":f").stdout.should eq("A\nb\n")
        File.read(File.join(root, "f")).should eq("B\nb\n")
      end
    end

    it "P39-O01 stashes only selected tracked #{format} worktree paths while retaining Git's full index parent" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        File.write(File.join(root, "g"), "g0\n")
        File.write(File.join(root, "h"), "h0\n")
        GitOracle.run(root, "add", "f", "g", "h")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "f-stage\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "f-work\n")
        File.write(File.join(root, "g"), "g-stage\n")
        GitOracle.run(root, "add", "g")
        File.write(File.join(root, "g"), "g-work\n")
        File.write(File.join(root, "h"), "h-work\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, message: "partial", paths: ["f"]).not_nil!

        File.read(File.join(root, "f")).should eq("f0\n")
        File.read(File.join(root, "g")).should eq("g-work\n")
        File.read(File.join(root, "h")).should eq("h-work\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("f0\n")
        GitOracle.run(root, "show", ":g").stdout.should eq("g-stage\n")
        GitOracle.run(root, "show", "#{entry.oid}:f").stdout.should eq("f-work\n")
        GitOracle.run(root, "show", "#{entry.oid}:g").stdout.should eq("g-stage\n")
        GitOracle.run(root, "show", "#{entry.oid}:h").stdout.should eq("h0\n")
        GitOracle.run(root, "show", "#{entry.index_oid}:g").stdout.should eq("g-stage\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("MM g\n M h\n")

        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        GitOracle.run(root, "stash", "apply", "-q", "stash@{0}")
        File.read(File.join(root, "f")).should eq("f-work\n")
        File.read(File.join(root, "g")).should eq("g-stage\n")
        File.read(File.join(root, "h")).should eq("h0\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(" M f\n M g\n")
      end
    end

    it "P39-O02 returns nil for #{format} selection with no selected change even when another path is staged" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        File.write(File.join(root, "g"), "g0\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "g"), "g-stage\n")
        GitOracle.run(root, "add", "g")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, paths: ["f"]).should be_nil
        repo.refs.resolve?("refs/stash").should be_nil
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("M  g\n")
      end
    end

    it "P39-O03 composes selected #{format} paths with keep_index without touching unselected worktree state" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        File.write(File.join(root, "g"), "g0\n")
        GitOracle.run(root, "add", "f", "g")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "f-stage\n")
        GitOracle.run(root, "add", "f")
        File.write(File.join(root, "f"), "f-work\n")
        File.write(File.join(root, "g"), "g-work\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        repo.stash.push(actor: actor, paths: ["f"], keep_index: true).should_not be_nil

        File.read(File.join(root, "f")).should eq("f-stage\n")
        GitOracle.run(root, "show", ":f").stdout.should eq("f-stage\n")
        File.read(File.join(root, "g")).should eq("g-work\n")
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("M  f\n M g\n")
      end
    end

    it "P39-O04 captures only selected #{format} untracked paths with include_untracked" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "f-work\n")
        File.write(File.join(root, "u"), "u\n")
        File.write(File.join(root, "v"), "v\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, paths: ["f", "u"], include_untracked: true).not_nil!

        entry.untracked_oid.should_not be_nil
        File.read(File.join(root, "f")).should eq("f0\n")
        File.exists?(File.join(root, "u")).should be_false
        File.read(File.join(root, "v")).should eq("v\n")
        GitOracle.run(root, "show", "#{entry.untracked_oid.not_nil!}:u").stdout.should eq("u\n")
        GitOracle.run(root, "show", "#{entry.untracked_oid.not_nil!}:v", check: false).success?.should be_false
        GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout.should eq("?? v\n")
      end
    end

    it "P39-O05 selects ignored #{format} leaves only through include_ignored" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, ".gitignore"), "*.tmp\n")
        GitOracle.run(root, "add", ".gitignore")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "one.tmp"), "one\n")
        File.write(File.join(root, "two.tmp"), "two\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /selected path/) do
          repo.stash.push(actor: actor, paths: ["one.tmp"], include_untracked: true)
        end
        entry = repo.stash.push(actor: actor, paths: ["one.tmp"], include_ignored: true).not_nil!
        File.exists?(File.join(root, "one.tmp")).should be_false
        File.read(File.join(root, "two.tmp")).should eq("two\n")
        GitOracle.run(root, "show", "#{entry.untracked_oid.not_nil!}:one.tmp").stdout.should eq("one\n")
      end
    end

    it "P39-O06 supports selected #{format} staged additions and unstaged deletions" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.delete(File.join(root, "f"))
        File.write(File.join(root, "n"), "new\n")
        GitOracle.run(root, "add", "n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        entry = repo.stash.push(actor: actor, paths: ["f", "n"]).not_nil!

        File.read(File.join(root, "f")).should eq("f0\n")
        File.exists?(File.join(root, "n")).should be_false
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should be_empty
        GitOracle.run(root, "show", "#{entry.oid}:n").stdout.should eq("new\n")
        GitOracle.run(root, "show", "#{entry.oid}:f", check: false).success?.should be_false
      end
    end

    it "P39-O07 rejects unmatched and staged-deleted #{format} literal selections before publication" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.delete(File.join(root, "f"))
        GitOracle.run(root, "add", "-u", "f")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /selected path/) { repo.stash.push(actor: actor, paths: ["f"]) }
        expect_raises(Git::Error, /selected path/) { repo.stash.push(actor: actor, paths: ["missing"]) }
        repo.refs.resolve?("refs/stash").should be_nil
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq("D  f\n")
      end
    end

    it "P39-O08 rejects #{format} literal selection with staged_only and duplicate paths" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "f"), "f0\n")
        GitOracle.run(root, "add", "f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "f"), "stage\n")
        GitOracle.run(root, "add", "f")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(ArgumentError) { repo.stash.push(actor: actor, paths: ["f"], staged_only: true) }
        expect_raises(Git::Error, /duplicate/) { repo.stash.push(actor: actor, paths: ["f", "f"]) }
        repo.refs.resolve?("refs/stash").should be_nil
      end
    end

    it "P39-O09 keeps #{format} path selection literal: empty and directory-style selections are refused" do
      GitOracle.with_repo(format: format) do |root|
        Dir.mkdir(File.join(root, "dir"))
        File.write(File.join(root, "dir", "f"), "base\n")
        GitOracle.run(root, "add", "dir/f")
        GitOracle.run(root, "commit", "-qm", "base")
        File.write(File.join(root, "dir", "f"), "work\n")

        repo = Git::Repository.new(root)
        actor = Git::Signature.new("S", "s@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /empty Git stash selected paths/) do
          repo.stash.push(actor: actor, paths: [] of String)
        end
        expect_raises(Git::Error, /selected path/) do
          repo.stash.push(actor: actor, paths: ["dir"])
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "dir", "f")).should eq("work\n")
      end
    end
  end
end
