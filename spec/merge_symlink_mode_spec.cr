require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P30 native Git symlink and independent mode merges" do
  ["sha1", "sha256"].each do |format|
    it "P30-O01 merges a symlink retarget alongside a separate #{format} local edit" do
      GitOracle.with_repo(format: format) do |root|
        File.symlink("unavailable-base", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "link"))
        File.symlink("unavailable-theirs", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "ours"), "local\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        result.commit_oid.should_not be_nil
        File.symlink?(File.join(root, "link")).should be_true
        File.readlink(File.join(root, "link")).should eq("unavailable-theirs")
        GitOracle.run(root, "ls-files", "--stage", "link").stdout.should start_with("120000 ")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-O02 preserves and aborts a conflicting #{format} symlink change" do
      GitOracle.with_repo(format: format) do |root|
        File.symlink("base", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "link"))
        File.symlink("theirs", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.delete(File.join(root, "link"))
        File.symlink("ours", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should eq(["link"])
        repo.merge_conflicts.first.base.not_nil!.mode.should eq("120000")
        GitOracle.run(root, "ls-files", "-u", "link").stdout.lines.size.should eq(3)
        File.symlink?(File.join(root, "link")).should be_true
        File.readlink(File.join(root, "link")).should eq("ours")
        repo.merge_abort
        File.readlink(File.join(root, "link")).should eq("ours")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-O03 supports a #{format} deletion-versus-symlink modification conflict and safe abort" do
      GitOracle.with_repo(format: format) do |root|
        File.symlink("base", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "link"))
        File.symlink("theirs", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        GitOracle.run(root, "rm", "-q", "link")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        repo.merge_three_way("topic", author: sig, committer: sig, message: "merge").conflicts.should eq(["link"])
        GitOracle.run(root, "ls-files", "-u", "link").stdout.lines.size.should eq(2)
        File.readlink(File.join(root, "link")).should eq("theirs")
        repo.merge_abort
        File.symlink?(File.join(root, "link")).should be_false
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-O04 merges #{format} independent executable-mode and text edits" do
      GitOracle.with_repo(format: format) do |root|
        path = File.join(root, "script")
        File.write(path, "first\nsecond\n")
        File.chmod(path, 0o644)
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.write(path, "FIRST\nsecond\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.chmod(path, 0o755)
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        # Confirm upstream Git performs this merge, not merely that a guessed
        # native resolution looks plausible.
        oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic")
        oracle.exit_code.should eq(0)
        oracle_content = File.read(path)
        oracle_mode = GitOracle.run(root, "ls-files", "--stage", "script").stdout.split(' ').first
        GitOracle.run(root, "merge", "--abort")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        result.commit_oid.should_not be_nil
        File.read(path).should eq(oracle_content)
        GitOracle.run(root, "ls-files", "--stage", "script").stdout.split(' ').first.should eq(oracle_mode)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end

describe "P30 native Git symlink safety and staging" do
  ["sha1", "sha256"].each do |format|
    it "P30-O05 stages an existing dangling #{format} symlink by target bytes" do
      GitOracle.with_repo(format: format) do |root|
        link = File.join(root, "link")
        File.symlink("missing-and-never-followed", link)
        repo = Git::Repository.new(root)
        oid = repo.stage_file("link")
        GitOracle.run(root, "ls-files", "--stage", "link").stdout.should eq("120000 #{oid} 0\tlink\n")
        kind, raw = repo.object(oid, 8_388_608) { }
        kind.should eq("blob")
        raw.should eq("missing-and-never-followed")
        File.symlink?(link).should be_true
      end
    end

    it "P30-O06 safely replaces #{format} a regular file with a symlink during merge" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "leaf"), "regular\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "leaf"))
        File.symlink("destination", File.join(root, "leaf"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "local"), "only ours\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        result = repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        result.conflicts.should be_empty
        File.symlink?(File.join(root, "leaf")).should be_true
        File.readlink(File.join(root, "leaf")).should eq("destination")
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end

    it "P30-O07 refuses a dirty #{format} symlink before creating merge metadata" do
      GitOracle.with_repo(format: format) do |root|
        File.symlink("base", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        File.delete(File.join(root, "link"))
        File.symlink("theirs", File.join(root, "link"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "theirs")
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "ours"), "local\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "ours")
        File.delete(File.join(root, "link"))
        File.symlink("dirty", File.join(root, "link"))
        repo = Git::Repository.new(root)
        sig = Git::Signature.new("A", "a@example.test", 1234567890_i64, 0)
        expect_raises(Git::Error, /dirty/) do
          repo.merge_three_way("topic", author: sig, committer: sig, message: "merge")
        end
        File.readlink(File.join(root, "link")).should eq("dirty")
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end
  end
end
