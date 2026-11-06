require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def snapshot(root : String, message : String) : String
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "commit", "-qm", message, "--allow-empty")
  GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
end

# Commits that exercise every diff-tree status.
private def diff_history(root : String) : Array(String)
  commits = [] of String
  Dir.mkdir_p(File.join(root, "dir", "nested"))
  File.write(File.join(root, "keep.txt"), "keep\n")
  File.write(File.join(root, "edit.txt"), "before\n")
  File.write(File.join(root, "exec.sh"), "#!/bin/sh\n")
  File.write(File.join(root, "dir", "nested", "deep.txt"), "deep\n")
  File.write(File.join(root, "becomes-dir"), "file\n")
  File.write(File.join(root, "becomes-link"), "regular\n")
  File.write(File.join(root, "moved.txt"), "moved content\n")
  File.write(File.join(root, "copy-a.txt"), "same\n")
  commits << snapshot(root, "base")
  File.write(File.join(root, "edit.txt"), "after\n")
  File.chmod(File.join(root, "exec.sh"), 0o755)
  File.delete(File.join(root, "becomes-dir"))
  Dir.mkdir(File.join(root, "becomes-dir"))
  File.write(File.join(root, "becomes-dir", "inside.txt"), "inside\n")
  File.delete(File.join(root, "becomes-link"))
  File.symlink("keep.txt", File.join(root, "becomes-link"))
  File.rename(File.join(root, "moved.txt"), File.join(root, "dir", "moved.txt"))
  File.rename(File.join(root, "dir", "nested"), File.join(root, "dir", "renamed-nested"))
  File.write(File.join(root, "added.txt"), "added\n")
  commits << snapshot(root, "changes")
  sub = commits.first
  GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{sub},vendor/sub")
  File.delete(File.join(root, "keep.txt"))
  GitOracle.run(root, "rm", "-q", "--cached", "keep.txt")
  GitOracle.run(root, "commit", "-qm", "submodule")
  commits << GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
  commits
end

describe "Git inspection" do
  ["sha1", "sha256"].each do |format|
    it "DIFF-O01 compares trees like git diff-tree -r (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        commits = diff_history(root)
        repo = Git::Repository.new(root)
        pairs = [{commits[0], commits[1]}, {commits[1], commits[2]}, {commits[0], commits[2]}, {commits[2], commits[0]}]
        pairs.each do |left, right|
          expected = GitOracle.run(root, "diff-tree", "-r", "--name-status", "--no-renames", left, right).stdout.lines
          repo.diff_trees(left, right).map(&.name_status).should eq(expected)
          renamed = GitOracle.run(root, "diff-tree", "-r", "--name-status", "-M100%", left, right).stdout.lines
          repo.diff_trees(left, right, renames: true).map(&.name_status).sort.should eq(renamed.sort)
          raw = GitOracle.run(root, "diff-tree", "-r", "--no-renames", "--no-abbrev", left, right).stdout.lines.map do |line|
            meta, path = line.split('\t', 2)
            fields = meta.lstrip(':').split(' ')
            {fields[4], path, fields[0], fields[1], fields[2], fields[3]}
          end
          repo.diff_trees(left, right).map do |change|
            zero = "0" * repo.object_format.hexsize
            {change.status.to_s, change.path, change.old_mode.try(&.rjust(6, '0')) || "000000",
             change.new_mode.try(&.rjust(6, '0')) || "000000", change.old_oid || zero, change.new_oid || zero}
          end.should eq(raw)
        end
        root_diff = GitOracle.run(root, "diff-tree", "-r", "--name-status", "--root", "--no-commit-id", commits[0]).stdout.lines
        repo.diff_trees(nil, commits[0]).map(&.name_status).should eq(root_diff)
        repo.diff_trees(commits[0], commits[1], paths: ["dir"]).map(&.name_status).should eq(
          GitOracle.run(root, "diff-tree", "-r", "--name-status", "--no-renames", commits[0], commits[1], "--", "dir").stdout.lines)
        repo.commit_changes(commits[1], renames: false).map(&.name_status).should eq(
          GitOracle.run(root, "show", "--name-status", "--format=", "--no-renames", commits[1]).stdout.lines.reject(&.empty?))
      end
    end
  end

  it "FSCK-O01 finds corrupt, missing and unreachable objects like git fsck" do
    GitOracle.with_repo do |root|
      commits = diff_history(root)
      repo = Git::Repository.new(root)
      clean = repo.fsck
      clean.ok?.should be_true
      dangling = GitOracle.run(root, "hash-object", "-w", "--stdin", input: "nobody points here\n").stdout.strip
      expected = GitOracle.run(root, "fsck", "--unreachable", "--no-progress").stdout.lines.compact_map do |line|
        line.starts_with?("unreachable ") ? line.split(' ')[2] : nil
      end.sort
      repo.fsck.unreachable.should eq(expected)
      expected.should contain(dangling)

      # Corrupt a reachable loose blob in place.
      blob = GitOracle.run(root, "rev-parse", "#{commits[1]}:edit.txt").stdout.strip
      path = File.join(root, ".git", "objects", blob[0, 2], blob[2..])
      File.chmod(path, 0o644)
      File.write(path, "not zlib")
      GitOracle.run(root, "fsck", "--no-progress", check: false).success?.should be_false
      report = repo.fsck
      report.ok?.should be_false
      report.corrupt.keys.should eq([blob])

      # Remove a reachable tree.
      tree = GitOracle.run(root, "rev-parse", "#{commits[0]}:dir/nested").stdout.strip
      File.delete(File.join(root, ".git", "objects", tree[0, 2], tree[2..]))
      GitOracle.run(root, "fsck", "--no-progress", check: false).stdout.should contain(tree)
      repo.fsck.missing.should contain(tree)
    end
  end
end
