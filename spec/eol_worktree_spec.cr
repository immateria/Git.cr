require "spec"
require "../src/git"
require "./support/git_oracle"

private def eol_file(root : String, path : String, content : String) : Nil
  full = File.join(root, path)
  Dir.mkdir_p(File.dirname(full))
  File.write(full, content)
end

private def eol_index_oid(repository : Git::Repository, path : String) : String
  repository.index_entries.find { |entry| entry.path == path && entry.stage == 0 }.not_nil!.oid
end

describe "native worktree text/EOL conversion" do
  ["sha1", "sha256"].each do |format|
    it "stages canonical #{format} blobs and compares CRLF worktrees cleanly" do
      GitOracle.with_repo(format: format) do |root|
        eol_file(root, ".gitattributes", "*.txt text eol=crlf\n")
        eol_file(root, "nested/file.txt", "first\r\nsecond\r\n")
        repo = Git::Repository.new(root)
        repo.stage_file(".gitattributes")
        oid = repo.stage_file("nested/file.txt")
        oid.should eq(Git::ObjectId.digest("blob", "first\nsecond\n", repo.object_format))
        GitOracle.run(root, "show", ":nested/file.txt").stdout.should eq("first\nsecond\n")
        repo.working_changes(include_untracked: false).should be_empty
        repo.working_file("nested/file.txt").should be_nil
        repo.diff.to_s.should eq("")
        repo.stage(["nested/file.txt"]).should be_empty
        GitOracle.run(root, "diff", "--exit-code").success?.should be_true
        File.read(File.join(root, "nested/file.txt")).should eq("first\r\nsecond\r\n")
      end
    end

    it "matches Git patches and status IDs for edited #{format} CRLF files" do
      GitOracle.with_repo(format: format) do |root|
        eol_file(root, ".gitattributes", "*.txt text eol=crlf\n")
        eol_file(root, "file.txt", "first\r\nsecond\r\n")
        repo = Git::Repository.new(root)
        repo.stage
        signature = Git::Signature.new("EOL", "eol@example.invalid", 1_700_000_000_i64, 0)
        repo.commit(author: signature, committer: signature, message: "base")
        eol_file(root, "file.txt", "first\r\nchanged\r\n")
        change = repo.working_changes(include_untracked: false).find { |item| item.path == "file.txt" }.not_nil!
        change.worktree_oid.should eq(Git::ObjectId.digest("blob", "first\nchanged\n", repo.object_format))
        comparison = repo.working_file("file.txt").not_nil!
        comparison.old_text.should eq("first\nsecond\n")
        comparison.new_text.should eq("first\nchanged\n")
        expected = GitOracle.run(root, "diff", "--no-color").stdout
        repo.diff.to_s.should eq(expected)
        repo.diff("HEAD").to_s.should eq(expected)
        repo.diff(attributes: false).to_s.should eq(expected)
        repo.stage(["file.txt"]).should eq(["file.txt"])
        eol_index_oid(repo, "file.txt").should eq(change.worktree_oid)
        repo.diff.to_s.should eq("")
      end
    end

    it "refreshes staged #{format} stat data when only worktree EOL bytes change" do
      GitOracle.with_repo(format: format) do |root|
        eol_file(root, ".gitattributes", "*.txt text eol=crlf\n")
        eol_file(root, "file.txt", "same\n")
        File.touch(File.join(root, "file.txt"), Time.unix(1_600_000_000))
        repo = Git::Repository.new(root)
        repo.stage_file(".gitattributes")
        oid = repo.stage_file("file.txt")
        signature = Git::Signature.new("EOL", "eol@example.invalid", 1_700_000_000_i64, 0)
        repo.commit(author: signature, committer: signature, message: "base")
        eol_file(root, "file.txt", "same\r\n")
        repo.stage(["file.txt"]).should be_empty
        eol_index_oid(repo, "file.txt").should eq(oid)
        File.read(File.join(root, "file.txt")).should eq("same\r\n")
        repo.working_changes(include_untracked: false).should be_empty
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end

  it "uses local autocrlf config by default and explicit config overrides" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "config", "core.autocrlf", "true")
      eol_file(root, "first", "one\r\ntwo\r\n")
      eol_file(root, "second", "one\r\ntwo\r\n")
      repo = Git::Repository.new(root)
      repo.stage_file("first").should eq(Git::ObjectId.digest("blob", "one\ntwo\n"))
      explicit = repo.config(command_values: [{"core.autocrlf", "false"}])
      repo.stage_file("second", config: explicit).should eq(Git::ObjectId.digest("blob", "one\r\ntwo\r\n"))
      repo.working_changes(include_untracked: false).should be_empty
    end
  end

  it "normalizes autocrlf=input through batch staging without changing the worktree" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "config", "core.autocrlf", "input")
      eol_file(root, "input.txt", "one\r\ntwo\r\n")
      repo = Git::Repository.new(root)
      repo.stage.should eq(["input.txt"])
      GitOracle.run(root, "show", ":input.txt").stdout.should eq("one\ntwo\n")
      File.read(File.join(root, "input.txt")).should eq("one\r\ntwo\r\n")
      repo.diff.to_s.should eq("")
    end
  end

  it "preserves automatic binary files and explicit raw blob APIs" do
    GitOracle.with_repo do |root|
      eol_file(root, ".gitattributes", "* text=auto\nraw -text\n")
      binary = "a\0b\r\n"
      eol_file(root, "binary", binary)
      eol_file(root, "raw", "raw\r\n")
      eol_file(root, "direct", "direct\r\n")
      repo = Git::Repository.new(root)
      repo.stage_file("binary").should eq(Git::ObjectId.digest("blob", binary))
      repo.stage_file("raw").should eq(Git::ObjectId.digest("blob", "raw\r\n"))
      repo.stage_blob("direct", "direct\r\n").should eq(Git::ObjectId.digest("blob", "direct\r\n"))
      repo.write_blob("object\r\n").should eq(Git::ObjectId.digest("blob", "object\r\n"))
      repo.diff.to_s.should eq("")
    end
  end

  it "never converts symlink targets" do
    GitOracle.with_repo do |root|
      eol_file(root, ".gitattributes", "* text eol=crlf\n")
      File.symlink("target\r\n", File.join(root, "link"))
      repo = Git::Repository.new(root)
      repo.stage_file("link").should eq(Git::ObjectId.digest("blob", "target\r\n"))
      repo.working_changes(include_untracked: false).should be_empty
      repo.diff.to_s.should eq("")
    end
  end

  it "uses indexed attributes when the worktree attribute file is absent" do
    GitOracle.with_repo do |root|
      eol_file(root, ".gitattributes", "*.txt text eol=lf\n")
      repo = Git::Repository.new(root)
      repo.stage_file(".gitattributes")
      File.delete(File.join(root, ".gitattributes"))
      eol_file(root, "file.txt", "one\r\ntwo\r\n")
      oid = repo.stage_file("file.txt")
      GitOracle.run(root, "show", ":file.txt").stdout.should eq("one\ntwo\n")
      GitOracle.run(root, "add", "file.txt")
      oid.should eq(GitOracle.run(root, "rev-parse", ":file.txt").stdout.strip)
    end
  end

  it "retains indexed CRLF under text=auto while explicit text normalizes it" do
    GitOracle.with_repo do |root|
      eol_file(root, ".gitattributes", "*.txt text=auto\n")
      eol_file(root, "file.txt", "one\r\ntwo\r\n")
      repo = Git::Repository.new(root)
      original = repo.stage_blob("file.txt", "one\r\ntwo\r\n")
      repo.stage_file("file.txt").should eq(original)
      repo.working_file("file.txt").should be_nil
      repo.diff.to_s.should eq("")
      eol_file(root, ".gitattributes", "*.txt text\n")
      repo.stage_file("file.txt").should eq(Git::ObjectId.digest("blob", "one\ntwo\n"))
    end
  end

  it "refuses unsafe EOL conversion before changing the index" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "config", "core.autocrlf", "input")
      GitOracle.run(root, "config", "core.safecrlf", "true")
      repo = Git::Repository.new(root)
      repo.stage_blob("kept", "kept\n")
      index = File.read(File.join(root, ".git", "index"))
      eol_file(root, "bad", "one\r\ntwo\r\n")
      expect_raises(Git::Error, /CRLF|LF|safe/) { repo.stage_file("bad") }
      File.read(File.join(root, ".git", "index")).should eq(index)
      expect_raises(Git::Error, /CRLF|LF|safe/) { repo.stage(["bad"]) }
      File.read(File.join(root, ".git", "index")).should eq(index)
    end
  end
  it "checks safecrlf for stat-dirty tracked files even when canonical content is unchanged" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      repo.stage_blob("file", "one\n")
      eol_file(root, "file", "one\n")
      GitOracle.run(root, "config", "core.autocrlf", "true")
      GitOracle.run(root, "config", "core.safecrlf", "true")
      index = File.read(File.join(root, ".git", "index"))
      GitOracle.run(root, "add", "file", check: false).success?.should be_false
      expect_raises(Git::Error, /CRLF|LF|safe/) { repo.stage(["file"]) }
      File.read(File.join(root, ".git", "index")).should eq(index)
    end
  end
end
