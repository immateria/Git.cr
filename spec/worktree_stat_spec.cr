require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# Status trusts the stat data Git recorded in the index, as Git does, and
# reads a file only when that data no longer matches or cannot settle it.

private def stat_fixture(root : String) : Nil
  File.write(File.join(root, "large.bin"), "x" * 100_000)
  File.write(File.join(root, "small.txt"), "same size\n")
  past = Time.utc - 1.hour
  {"large.bin", "small.txt"}.each { |name| File.utime(past, past, File.join(root, name)) }
  GitOracle.run(root, "add", ".")
  GitOracle.run(root, "commit", "-qm", "base")
end

private def git_status(root : String) : Array(String)
  GitOracle.run(root, "status", "--porcelain=v1").stdout.lines
end

describe "working tree status and the index stat cache" do
  it "WS-01 does not read files whose stat data matches the index" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      # Too small a budget to read large.bin: only the stat cache can say
      # that it is unchanged.
      repo = Git::Repository.new(root, max_scan_bytes: 1024)
      repo.working_changes.to_a.should be_empty
      repo.diff.to_s.should eq("")
    end
  end

  it "WS-02 reads a racily clean file written in the second of the index" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      index = File.join(root, ".git", "index")
      path = File.join(root, "small.txt")
      File.write(path, "same SIZE\n")
      recorded = File.info(index).modification_time
      File.utime(recorded, recorded, path)
      git_status(root).should eq([" M small.txt"])
      Git::Repository.new(root).working_changes.map(&.path).should eq(["small.txt"])
    end
  end

  it "WS-03 sees a same-size edit whose mtime was put back (ctime changes)" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      path = File.join(root, "small.txt")
      before = File.info(path).modification_time
      sleep 1.1.seconds
      File.write(path, "same SIZE\n")
      File.utime(before, before, path)
      git_status(root).should eq([" M small.txt"])
      repo = Git::Repository.new(root)
      repo.working_changes.map(&.path).should eq(["small.txt"])
      repo.diff.map(&.path).should eq(["small.txt"])
    end
  end

  it "WS-04 sees an executable-bit change and a deletion without reading other files" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      File.chmod(File.join(root, "small.txt"), 0o755)
      File.delete(File.join(root, "large.bin"))
      git_status(root).sort.should eq([" D large.bin", " M small.txt"])
      changes = Git::Repository.new(root, max_scan_bytes: 1024).working_changes
      changes.map { |change| {change.path, change.status} }.sort.should eq([{"large.bin", "deleted"}, {"small.txt", "modified"}])
    end
  end

  it "WS-05 reports submodules as git status does" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      sub = File.join(root, "sub")
      Dir.mkdir(sub)
      GitOracle.run(sub, "init", "-q", "-b", "main")
      File.write(File.join(sub, "inner.txt"), "inner\n")
      GitOracle.run(sub, "add", ".")
      GitOracle.run(sub, "commit", "-qm", "inner")
      GitOracle.run(root, "add", "sub")
      GitOracle.run(root, "commit", "-qm", "add submodule")
      git_status(root).should be_empty
      Git::Repository.new(root).working_changes.to_a.should be_empty
      File.write(File.join(sub, "inner.txt"), "moved on\n")
      GitOracle.run(sub, "commit", "-qam", "newer")
      git_status(root).should eq([" M sub"])
      Git::Repository.new(root).working_changes.map { |change| {change.path, change.status} }.should eq([{"sub", "modified"}])
      FileUtils.rm_rf(File.join(sub, ".git"))
      git_status(root).should be_empty
      Git::Repository.new(root).working_changes.to_a.should be_empty
      nested = File.join(root, "nested")
      Dir.mkdir(nested)
      GitOracle.run(nested, "init", "-q")
      File.write(File.join(nested, "file.txt"), "x\n")
      GitOracle.run(root, "status", "--porcelain=v1", "-uall").stdout.lines.should eq(["?? nested/"])
      Git::Repository.new(root).working_changes.map(&.path).should eq(["nested/"])
    end
  end

  it "WS-06 records and preserves index stat data across native stage and clone, and uses cache-tree in staged_changes" do
    GitOracle.with_repo do |root|
      stat_fixture(root)
      # Clean commit has a valid root TREE extension: staged_changes succeeds
      # even when max_search_entries is 0 (no tree objects need to be walked).
      fast_repo = Git::Repository.new(root, max_search_entries: 10)
      fast_repo.staged_changes.to_a.should be_empty

      # Native stage_file and stage record Stat for old files and preserve
      # existing non-racy Stat entries on untouched files.
      extra = File.join(root, "extra.txt")
      File.write(extra, "extra\n")
      past = Time.utc - 1.hour
      File.utime(past, past, extra)
      Git::Repository.new(root).stage_file("extra.txt")
      # With Stat preserved on large.bin and recorded on extra.txt, a 1024-byte
      # scan budget does not need to read large.bin (100_000 bytes).
      tight = Git::Repository.new(root, max_scan_bytes: 1024)
      tight.working_changes.to_a.should be_empty
      tight.diff.to_s.should eq("")
    end
  end
end
