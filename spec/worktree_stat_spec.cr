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
end
