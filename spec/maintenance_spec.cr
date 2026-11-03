require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def maintenance_history(root : String) : String
  GitOracle.run(root, "config", "core.logAllRefUpdates", "true")
  8.times do |i|
    Dir.mkdir_p(File.join(root, "dir#{i % 3}"))
    File.write(File.join(root, "dir#{i % 3}", "file.txt"), "content #{i}\n" * (i + 5))
    GitOracle.run(root, "add", "-A")
    GitOracle.run(root, "commit", "-qm", "commit #{i}")
    GitOracle.run(root, "repack", "-q") if i == 3
  end
  GitOracle.run(root, "branch", "side", "HEAD~2")
  GitOracle.run(root, "branch", "nested/deep/branch", "HEAD~4")
  GitOracle.run(root, "tag", "-a", "v1", "-m", "v1\n", "HEAD~1")
  GitOracle.run(root, "tag", "-a", "v1-outer", "-m", "outer\n", "v1")
  GitOracle.run(root, "tag", "light", "HEAD~3")
  GitOracle.run(root, "update-ref", "refs/remotes/origin/main", "HEAD")
  GitOracle.run(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
  # Staged-only content and an unreachable loose object.
  File.write(File.join(root, "staged.txt"), "only in the index\n")
  GitOracle.run(root, "add", "staged.txt")
  GitOracle.run(root, "hash-object", "-w", "--stdin", input: "dangling\n").stdout.strip
end

describe "Git maintenance" do
  ["sha1", "sha256"].each do |format|
    it "MAINT-O01 repacks into one pack and prunes packed loose objects (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        dangling = maintenance_history(root)
        repo = Git::Repository.new(root)
        old_packs = Dir.glob(File.join(root, ".git", "objects", "pack", "*.pack"))
        old_packs.size.should be > 0
        result = repo.repack
        result.removed_packs.size.should eq(old_packs.size)
        packs = Dir.glob(File.join(root, ".git", "objects", "pack", "*.pack"))
        packs.size.should eq(1)
        GitOracle.run(root, "fsck", "--strict", "--no-dangling")
        GitOracle.run(root, "verify-pack", packs.first.sub(/\.pack\z/, ".idx"))
        # Only the unreachable object stays loose.
        loose = Dir.glob(File.join(root, ".git", "objects", "??", "*")).map { |path| File.basename(File.dirname(path)) + File.basename(path) }
        loose.should eq([dangling])
        GitOracle.run(root, "cat-file", "-p", ":staged.txt").stdout.should eq("only in the index\n")
        GitOracle.run(root, "rev-list", "--objects", "--all", "--reflog", "--indexed-objects").stdout.lines.size.should eq(result.objects)
        repo.rev_parse("v1-outer^{commit}").should eq(GitOracle.run(root, "rev-parse", "v1-outer^{commit}").stdout.strip)
      end
    end
  end

  it "MAINT-O02 packs refs exactly as git pack-refs --all" do
    GitOracle.with_repo do |root|
      maintenance_history(root)
      copy = File.join(File.dirname(root), "copy")
      FileUtils.cp_r(root, copy)
      Git::Repository.new(root).pack_refs.should eq(GitOracle.run(root, "for-each-ref").stdout.lines.reject(&.includes?("origin/HEAD")).size)
      GitOracle.run(copy, "pack-refs", "--all")
      File.read(File.join(root, ".git", "packed-refs")).should eq(File.read(File.join(copy, ".git", "packed-refs")))
      loose = ->(base : String) { Dir.glob(File.join(base, ".git", "refs", "**", "*")).select { |path| File.file?(path) }.map(&.sub(base, "")).sort }
      loose.call(root).should eq(loose.call(copy))
      Dir.exists?(File.join(root, ".git", "refs", "heads", "nested")).should eq(Dir.exists?(File.join(copy, ".git", "refs", "heads", "nested")))
      GitOracle.run(root, "for-each-ref").stdout.should eq(GitOracle.run(copy, "for-each-ref").stdout)
      GitOracle.run(root, "symbolic-ref", "refs/remotes/origin/HEAD").stdout.strip.should eq("refs/remotes/origin/main")
      repo = Git::Repository.new(root)
      repo.gc.packed_refs.should be > 0
      GitOracle.run(root, "fsck", "--strict", "--no-dangling")
    end
  end
end
