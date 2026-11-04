require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# Each scenario builds one fixture, copies it, runs git on one copy and the
# library on the other, and compares index, status and worktree layout.

private def commit_all(root : String, message : String) : Nil
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "commit", "-qm", message)
end

private def write(root : String, path : String, text : String) : Nil
  full = File.join(root, path)
  Dir.mkdir_p(File.dirname(full))
  File.write(full, text)
end

private def base_fixture(root : String) : Nil
  GitOracle.run(root, "config", "core.filemode", "true")
  write(root, ".gitignore", "*.log\n")
  write(root, "a.txt", "alpha\n")
  write(root, "d/b.txt", "bravo\n")
  write(root, "sub/dir/c.txt", "charlie\n")
  write(root, "sub/dir/e.txt", "echo\n")
  write(root, "sub/keep.txt", "keep\n")
  write(root, "run.sh", "#!/bin/sh\n")
  File.chmod(File.join(root, "run.sh"), 0o755)
  File.symlink("a.txt", File.join(root, "link"))
  commit_all(root, "base")
end

# Worktree layout: every path below the root except .git, directories
# marked with a trailing slash, symlinks with their target.
private def layout(root : String, prefix : String = "") : Array(String)
  found = [] of String
  Dir.each_child(File.join(root, prefix)) do |name|
    next if prefix.empty? && name == ".git"
    relative = prefix.empty? ? name : "#{prefix}/#{name}"
    full = File.join(root, relative)
    if File.symlink?(full)
      found << "#{relative} -> #{File.readlink(full)}"
    elsif Dir.exists?(full)
      found << "#{relative}/"
      found.concat(layout(root, relative))
    else
      found << "#{relative} #{File.info(full).permissions.value & 0o111 != 0 ? "x" : "-"}"
    end
  end
  found.sort
end

private def snapshot(root : String) : Array(String)
  [GitOracle.run(root, "ls-files", "-s").stdout,
   GitOracle.run(root, "status", "--porcelain=v1", "--untracked-files=all").stdout] + layout(root)
end

private def copy_repo(root : String) : String
  target = File.join(File.dirname(root), "library")
  Process.run("cp", ["-a", root, target]).success?.should be_true
  target
end

private def compare(setup : Proc(String, Nil), git_args : Array(String), &action : Git::Repository -> Array(String)) : Nil
  GitOracle.with_repo do |root|
    base_fixture(root)
    setup.call(root)
    other = copy_repo(root)
    GitOracle.run_args(root, git_args)
    returned = action.call(Git::Repository.new(other))
    snapshot(other).should eq(snapshot(root))
    File.exists?(File.join(other, ".git", "index.lock")).should be_false
    GitOracle.run(other, "fsck", "--no-dangling")
    returned.should eq(returned.sort)
  end
end

# Both sides refuse and leave the repository as it was.
private def refused(setup : Proc(String, Nil), git_args : Array(String), git_atomic : Bool = true, &action : Git::Repository -> Nil) : Exception
  GitOracle.with_repo do |root|
    base_fixture(root)
    setup.call(root)
    other = copy_repo(root)
    before = snapshot(root)
    GitOracle.run_args(root, git_args, check: false).success?.should be_false
    snapshot(root).should eq(before) if git_atomic
    error = nil.as(Exception?)
    begin
      action.call(Git::Repository.new(other))
    rescue ex : Git::Error
      error = ex
    end
    error.should_not be_nil
    snapshot(other).should eq(before)
    return error.not_nil!
  end
  raise "unreachable"
end

# Modify, delete, add (also in a new directory), ignore, chmod, symlink.
private def churn(root : String) : Nil
  write(root, "a.txt", "alpha changed\n")
  File.delete(File.join(root, "d/b.txt"))
  write(root, "new.txt", "new\n")
  write(root, "newdir/deep/n.txt", "n\n")
  write(root, "x.log", "ignored\n")
  write(root, "sub/dir/y.log", "ignored\n")
  write(root, "tool.sh", "#!/bin/sh\n")
  File.chmod(File.join(root, "tool.sh"), 0o755)
  File.chmod(File.join(root, "sub/keep.txt"), 0o755)
  File.symlink("new.txt", File.join(root, "link2"))
  File.delete(File.join(root, "link"))
  File.symlink("elsewhere", File.join(root, "link"))
  write(root, "sub/dir/c.txt", "charlie changed\n")
end

private def nothing(root : String) : Nil
end

describe "Repository#stage" do
  it "matches git add -A over the whole tree" do
    compare(->churn(String), ["add", "-A"]) { |repo| repo.stage }
  end

  it "matches git add -u" do
    compare(->churn(String), ["add", "-u"]) { |repo| repo.stage(tracked_only: true) }
  end

  it "matches git add -A on directory paths" do
    compare(->churn(String), ["add", "-A", "--", "d", "sub"]) { |repo| repo.stage(["d", "sub/"]) }
  end

  it "matches git add -A on a new directory and on single files" do
    compare(->churn(String), ["add", "-A", "--", "newdir", "a.txt", "link"]) { |repo| repo.stage(["newdir", "a.txt", "link"]) }
  end

  it "matches git add -u on a path and git add -A . " do
    compare(->churn(String), ["add", "-u", "--", "sub"]) { |repo| repo.stage(["sub"], tracked_only: true) }
    compare(->churn(String), ["add", "-A", "."]) { |repo| repo.stage(["."]) }
  end

  it "stages a file replaced by a directory" do
    swap = ->(root : String) do
      File.delete(File.join(root, "a.txt"))
      write(root, "a.txt/inner.txt", "inner\n")
    end
    compare(swap, ["add", "-A"]) { |repo| repo.stage }
  end

  it "does nothing and writes nothing when the tree is clean" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      repo = Git::Repository.new(root)
      before = File.read(File.join(root, ".git", "index"))
      repo.stage.should eq([] of String)
      File.read(File.join(root, ".git", "index")).should eq(before)
    end
  end

  it "reports exactly the paths whose entries changed" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      churn(root)
      Git::Repository.new(root).stage.should eq(
        ["a.txt", "d/b.txt", "link", "link2", "new.txt", "newdir/deep/n.txt", "sub/dir/c.txt", "sub/keep.txt", "tool.sh"])
    end
  end

  it "follows core.filemode like git" do
    chmod = ->(root : String) do
      GitOracle.run(root, "config", "core.filemode", "false")
      File.chmod(File.join(root, "a.txt"), 0o755)
      File.chmod(File.join(root, "run.sh"), 0o644)
      write(root, "run.sh", "#!/bin/sh\nchanged\n")
      write(root, "fresh.sh", "#!/bin/sh\n")
      File.chmod(File.join(root, "fresh.sh"), 0o755)
    end
    compare(chmod, ["add", "-A"]) do |repo|
      repo.stage(config: repo.config)
    end
  end

  it "resolves a conflicted path to stage 0 like git add" do
    conflict = ->(root : String) do
      GitOracle.run(root, "checkout", "-q", "-b", "other")
      write(root, "a.txt", "alpha other\n")
      write(root, "d/b.txt", "bravo other\n")
      commit_all(root, "other")
      GitOracle.run(root, "checkout", "-q", "main")
      write(root, "a.txt", "alpha main\n")
      write(root, "d/b.txt", "bravo main\n")
      commit_all(root, "main")
      GitOracle.run(root, "merge", "other", check: false)
      GitOracle.run(root, "ls-files", "-u").stdout.should contain("a.txt")
      write(root, "a.txt", "alpha resolved\n")
      File.delete(File.join(root, "d/b.txt"))
    end
    compare(conflict, ["add", "-A", "--", "a.txt", "d/b.txt"]) { |repo| repo.stage(["a.txt", "d/b.txt"]) }
    compare(conflict, ["add", "-u"]) { |repo| repo.stage(tracked_only: true) }
  end

  it "refuses a named ignored untracked file, writing nothing" do
    error = refused(->churn(String), ["add", "-A", "--", "a.txt", "x.log"], git_atomic: false) { |repo| repo.stage(["a.txt", "x.log"]) }
    error.should be_a(Git::Staging::IgnoredPaths)
    error.as(Git::Staging::IgnoredPaths).paths.should eq(["x.log"])
    error.message.to_s.should contain("ignored by one of your .gitignore files")
  end

  it "does not refuse a directory holding only ignored files" do
    ignored_dir = ->(root : String) do
      write(root, "only/z.log", "z\n")
    end
    compare(ignored_dir, ["add", "-A", "--", "only"]) { |repo| repo.stage(["only"]) }
  end

  it "refuses a path that matches nothing" do
    error = refused(->churn(String), ["add", "-A", "--", "a.txt", "missing.txt"]) { |repo| repo.stage(["a.txt", "missing.txt"]) }
    error.should be_a(Git::Staging::PathspecMismatch)
    error.as(Git::Staging::PathspecMismatch).pathspec.should eq("missing.txt")
    refused(->churn(String), ["add", "-u", "--", "missing.txt"]) { |repo| repo.stage(["missing.txt"], tracked_only: true) }
      .should be_a(Git::Staging::PathspecMismatch)
    refused(->churn(String), ["add", "-u", "--", "new.txt"]) { |repo| repo.stage(["new.txt"], tracked_only: true) }
      .should be_a(Git::Staging::PathspecMismatch)
  end

  it "raises instead of truncating past the path budget" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      churn(root)
      before = File.read(File.join(root, ".git", "index"))
      expect_raises(Git::Error, /budget/) { Git::Repository.new(root).stage(max_paths: 3) }
      File.read(File.join(root, ".git", "index")).should eq(before)
    end
  end

  it "leaves submodule entries and embedded repositories alone" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      oid = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{oid},mod")
      write(root, "mod/inside.txt", "inside\n")
      write(root, "embedded/inside.txt", "inside\n")
      Dir.mkdir_p(File.join(root, "embedded/.git"))
      write(root, "a.txt", "changed\n")
      repo = Git::Repository.new(root)
      repo.stage.should eq(["a.txt"])
      GitOracle.run(root, "ls-files", "-s").stdout.should contain("160000 #{oid} 0\tmod")
    end
  end

  it "publishes once and honors cancellation without leaving a lock" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      churn(root)
      repo = Git::Repository.new(root)
      before = File.read(File.join(root, ".git", "index"))
      calls = 0
      stop = -> do
        calls += 1
        raise Git::Error.new("cancelled") if calls > 40
      end
      expect_raises(Git::Error, "cancelled") { repo.stage(check: stop) }
      File.read(File.join(root, ".git", "index")).should eq(before)
      File.exists?(File.join(root, ".git", "index.lock")).should be_false
    end
  end
end

describe "Repository#remove" do
  it "matches git rm of a clean file" do
    compare(->nothing(String), ["rm", "-q", "--", "a.txt"]) { |repo| repo.remove(["a.txt"]) }
  end

  it "matches git rm of nested files, removing emptied parents" do
    compare(->nothing(String), ["rm", "-q", "--", "sub/dir/c.txt", "sub/dir/e.txt"]) do |repo|
      repo.remove(["sub/dir/c.txt", "sub/dir/e.txt"])
    end
  end

  it "keeps a parent that still holds files" do
    compare(->nothing(String), ["rm", "-q", "--", "sub/dir/c.txt"]) { |repo| repo.remove(["sub/dir/c.txt"]) }
  end

  it "matches git rm -r on a directory and a symlink" do
    compare(->nothing(String), ["rm", "-q", "-r", "--", "sub", "link"]) { |repo| repo.remove(["sub/", "link"], recursive: true) }
  end

  it "matches git rm --cached and keeps the file" do
    compare(->nothing(String), ["rm", "-q", "--cached", "--", "a.txt", "d/b.txt"]) do |repo|
      repo.remove(["a.txt", "d/b.txt"], cached: true)
    end
  end

  it "removes an already deleted file from the index" do
    gone = ->(root : String) { File.delete(File.join(root, "a.txt")) }
    compare(gone, ["rm", "-q", "--", "a.txt"]) { |repo| repo.remove(["a.txt"]) }
  end

  it "removes a deleted file even when its removal is staged content" do
    gone = ->(root : String) do
      write(root, "a.txt", "staged\n")
      GitOracle.run(root, "add", "a.txt")
      File.delete(File.join(root, "a.txt"))
    end
    compare(gone, ["rm", "-q", "--", "a.txt"]) { |repo| repo.remove(["a.txt"]) }
  end

  it "refuses local modifications, and -f overrides" do
    modified = ->(root : String) { write(root, "a.txt", "edited\n") }
    error = refused(modified, ["rm", "-q", "--", "a.txt"]) { |repo| repo.remove(["a.txt"]) }
    error.should be_a(Git::Removal::Refused)
    refusal = error.as(Git::Removal::Refused)
    refusal.modified.should eq(["a.txt"])
    refusal.staged_only.should be_empty
    refusal.both.should be_empty
    error.message.to_s.should contain("has local modifications")
    compare(modified, ["rm", "-q", "-f", "--", "a.txt"]) { |repo| repo.remove(["a.txt"], force: true) }
    compare(modified, ["rm", "-q", "--cached", "--", "a.txt"]) { |repo| repo.remove(["a.txt"], cached: true) }
  end

  it "refuses staged changes, and -f overrides; --cached allows them" do
    staged = ->(root : String) do
      write(root, "a.txt", "staged\n")
      write(root, "added.txt", "added\n")
      GitOracle.run(root, "add", "a.txt", "added.txt")
    end
    error = refused(staged, ["rm", "-q", "--", "a.txt", "added.txt"]) { |repo| repo.remove(["a.txt", "added.txt"]) }
    error.as(Git::Removal::Refused).staged_only.should eq(["a.txt", "added.txt"])
    error.message.to_s.should contain("has changes staged in the index")
    compare(staged, ["rm", "-q", "-f", "--", "a.txt", "added.txt"]) { |repo| repo.remove(["a.txt", "added.txt"], force: true) }
    compare(staged, ["rm", "-q", "--cached", "--", "a.txt", "added.txt"]) { |repo| repo.remove(["a.txt", "added.txt"], cached: true) }
  end

  it "refuses content staged differently from both file and HEAD, and -f overrides" do
    both = ->(root : String) do
      write(root, "a.txt", "staged\n")
      GitOracle.run(root, "add", "a.txt")
      write(root, "a.txt", "worktree\n")
      write(root, "d/b.txt", "other staged\n")
      GitOracle.run(root, "add", "d/b.txt")
      write(root, "d/b.txt", "other worktree\n")
    end
    error = refused(both, ["rm", "-q", "--", "a.txt", "d/b.txt"]) { |repo| repo.remove(["a.txt", "d/b.txt"]) }
    error.as(Git::Removal::Refused).both.should eq(["a.txt", "d/b.txt"])
    error.as(Git::Removal::Refused).paths.should eq(["a.txt", "d/b.txt"])
    error.message.to_s.should contain("has staged content different from both the file and the HEAD")
    refused(both, ["rm", "-q", "--cached", "--", "a.txt"]) { |repo| repo.remove(["a.txt"], cached: true) }
      .should be_a(Git::Removal::Refused)
    compare(both, ["rm", "-q", "-f", "--", "a.txt", "d/b.txt"]) { |repo| repo.remove(["a.txt", "d/b.txt"], force: true) }
    compare(both, ["rm", "-q", "-f", "--cached", "--", "a.txt"]) { |repo| repo.remove(["a.txt"], force: true, cached: true) }
  end

  it "refuses an executable-bit change like git" do
    chmod = ->(root : String) { File.chmod(File.join(root, "a.txt"), 0o755) }
    refused(chmod, ["rm", "-q", "--", "a.txt"]) { |repo| repo.remove(["a.txt"]) }
      .should be_a(Git::Removal::Refused)
  end

  it "refuses a directory without recursive" do
    error = refused(->nothing(String), ["rm", "-q", "--", "sub"]) { |repo| repo.remove(["sub"]) }
    error.should be_a(Git::Removal::NotRecursive)
    error.as(Git::Removal::NotRecursive).path.should eq("sub")
  end

  it "refuses an untracked or unknown path" do
    refused(->churn(String), ["rm", "-q", "--", "new.txt"]) { |repo| repo.remove(["new.txt"]) }
      .should be_a(Git::Staging::PathspecMismatch)
    refused(->nothing(String), ["rm", "-q", "--", "a.txt", "nope"]) { |repo| repo.remove(["a.txt", "nope"]) }
      .should be_a(Git::Staging::PathspecMismatch)
  end

  it "removes a conflicted path's stages" do
    conflict = ->(root : String) do
      GitOracle.run(root, "checkout", "-q", "-b", "other")
      write(root, "a.txt", "alpha other\n")
      commit_all(root, "other")
      GitOracle.run(root, "checkout", "-q", "main")
      write(root, "a.txt", "alpha main\n")
      commit_all(root, "main")
      GitOracle.run(root, "merge", "other", check: false)
    end
    compare(conflict, ["rm", "-q", "-f", "--", "a.txt"]) { |repo| repo.remove(["a.txt"], force: true) }
  end

  it "stages and removes in sequence like git" do
    GitOracle.with_repo do |root|
      base_fixture(root)
      churn(root)
      other = copy_repo(root)
      GitOracle.run(root, "add", "-A")
      GitOracle.run(root, "rm", "-q", "-r", "-f", "--", "sub")
      repo = Git::Repository.new(other)
      repo.stage
      repo.remove(["sub"], recursive: true, force: true).should eq(
        ["sub/dir/c.txt", "sub/dir/e.txt", "sub/keep.txt"])
      snapshot(other).should eq(snapshot(root))
    end
  end
end
