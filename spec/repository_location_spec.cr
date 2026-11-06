require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# P05: all fixtures are real Git repositories, and Git is executed only by
# test code. The native implementation must not consult Git or host ENV.
describe "P05 repository identity and discovery" do
  it "P05-O01 reads SHA-1 and SHA-256 bare clones without a working tree" do
    ["sha1", "sha256"].each do |format|
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "tracked.txt"), "bare repository \n")
        GitOracle.run(root, "add", "tracked.txt")
        GitOracle.run(root, "commit", "-qm", "base")
        bare = File.join(File.dirname(root), "bare-#{format}.git")
        GitOracle.run(root, "clone", "--bare", "-q", root, bare)
        store = Git::Repository.new(bare)
        store.bare?.should be_true
        store.work_tree.should be_nil
        store.root.should eq(File.realpath(bare))
        store.head.oid.should eq(GitOracle.run(bare, "rev-parse", "HEAD").stdout.strip)
        store.read_head_file("tracked.txt", max_bytes: 4096).should eq("bare repository \n")
        expect_raises(Git::Error, /bare/) { store.working_changes(max_bytes: 4096, limit: 20) }
        expect_raises(Git::Error, /bare/) { store.working_file("tracked.txt", max_bytes: 4096) }
      end
    end
  end

  it "P05-O02 supports a host-selected external gitfile directory, rejecting implicit access" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "one.txt"), "one\n")
      GitOracle.run(root, "add", "one.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      separate = File.join(File.dirname(root), "external-metadata")
      GitOracle.run(root, "init", "-q", "--separate-git-dir", separate)
      Git::Repository.new(root).head.oid.should eq(GitOracle.run(root, "rev-parse", "HEAD").stdout.strip)
      expect_raises(Git::Error) { Git::Repository.new(root, follow_gitfile: false) }
      store = Git::Repository.new(root, git_dir: separate)
      store.bare?.should be_false
      store.work_tree.should eq(File.realpath(root))
      store.head.oid.should eq(GitOracle.run(root, "rev-parse", "HEAD").stdout.strip)
      store.read_head_file("one.txt", max_bytes: 4096).should eq("one\n")
      staged = store.staged_changes(max_bytes: 128 * 1024, limit: 20)
      truncated = staged.truncated?
      staged.should be_empty
      truncated.should be_false
      store.revalidate!
      File.write(File.join(root, ".git"), "gitdir: #{File.join(File.dirname(root), "wrong")}\n")
      # Explicit GIT_DIR wins over a .git pointer, as in upstream Git.
      store.revalidate!
      Git::Repository.new(root, git_dir: separate).head.should eq(store.head)
    end
  end

  it "P05-O03 discovers nested paths but stops at a caller-selected ceiling" do
    GitOracle.with_repo do |root|
      inside = File.join(root, "deep", "nested")
      Dir.mkdir_p(inside)
      File.write(File.join(root, "top.txt"), "file\n")
      GitOracle.run(root, "add", "top.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      expect_raises(Git::Error) { Git::Repository.new(inside) }
      store = Git::Repository.new(inside, discover: true)
      store.root.should eq(File.realpath(root))
      store.head.oid.should eq(GitOracle.run(inside, "rev-parse", "HEAD").stdout.strip)
      expect_raises(Git::Error) { Git::Repository.new(inside, discover: true, discovery_ceiling: inside) }
      store.revalidate!
      nested_repo = File.join(root, "deep", "nested", "repo")
      Dir.mkdir_p(nested_repo)
      GitOracle.run(nested_repo, "init", "-q")
      Git::Repository.new(nested_repo, discover: true).root.should eq(File.realpath(nested_repo))
    end
  end

  it "P05-O04 preserves linked worktree private HEAD and index with shared objects" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "shared.txt"), "base\n")
      GitOracle.run(root, "add", "shared.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      linked = File.join(File.dirname(root), "linked")
      GitOracle.run(root, "worktree", "add", "-q", "-b", "feature", linked)
      admin = File.join(root, ".git", "worktrees", "linked")
      Git::Repository.new(linked).head.symref_target.should eq("refs/heads/feature")
      expect_raises(Git::Error) { Git::Repository.new(linked, follow_gitfile: false) }
      store = Git::Repository.new(linked, linked_worktree_admin_dir: admin)
      store.head.symref_target.should eq("refs/heads/feature")
      store.head.oid.should eq(GitOracle.run(linked, "rev-parse", "HEAD").stdout.strip)
      File.write(File.join(linked, "shared.txt"), "new worktree content\n")
      GitOracle.run(linked, "add", "shared.txt")
      store.staged_changes(max_bytes: 128 * 1024, limit: 10).map(&.path).should eq(["shared.txt"])
      Git::Repository.new(root).staged_changes(max_bytes: 128 * 1024, limit: 10).should be_empty
      GitOracle.run(linked, "update-ref", "refs/worktree/private", "HEAD")
      store.refs.resolve?("refs/worktree/private").should eq(GitOracle.run(linked, "rev-parse", "refs/worktree/private").stdout.strip)
      Git::Repository.new(root).refs.resolve?("refs/worktree/private").should be_nil
      store.revalidate!
      backlink = File.join(admin, "gitdir")
      original = File.read(backlink)
      begin
        File.write(backlink, File.join(root, ".git") + "\n")
        expect_raises(Git::Error) { store.revalidate! }
      ensure
        File.write(backlink, original)
      end
      store.revalidate!
    end
  end

  it "P05-O05 accepts selected relative Git directory/worktree coordinates" do
    GitOracle.with_repo do |root|
      outside = File.dirname(root)
      separate = File.join(outside, "selected-meta")
      GitOracle.run(root, "init", "-q", "--separate-git-dir", separate)
      sub = File.join(root, "child")
      Dir.mkdir_p(sub)
      from = sub
      # GIT_DIR relative to -C from; GIT_WORK_TREE relative to the same
      # caller cwd. The library does not silently inherit process ENV.
      store = Git::Repository.new(from, git_dir: "../../selected-meta", work_tree: "..")
      store.bare?.should be_false
      store.root.should eq(File.realpath(root))
      store.revalidate!
      store.head.symref_target.should eq(GitOracle.run(root, "symbolic-ref", "HEAD").stdout.strip)
      git_env = {"GIT_DIR" => "../../selected-meta", "GIT_WORK_TREE" => ".."}
      from_env = Git::Repository.from_environment(from, git_env)
      from_env.root.should eq(File.realpath(root))
      from_env.head.should eq(store.head)
      from_env.revalidate!
      GitOracle.run(from, "rev-parse", "--show-toplevel", extra_env: git_env).stdout.strip.should eq(from_env.root)
    end
  end

  it "P05-O07 honors core.worktree only when the external selection is trusted" do
    GitOracle.with_repo do |root|
      external = File.join(File.dirname(root), "configured-worktree")
      Dir.mkdir_p(external)
      GitOracle.run(root, "config", "core.worktree", external)
      GitOracle.run(root, "rev-parse", "--show-toplevel").stdout.strip.should eq(external)
      expect_raises(Git::Error, /core.worktree/) { Git::Repository.new(root) }
      selected = Git::Repository.new(root, work_tree: external)
      selected.work_tree.should eq(external)
      selected.bare?.should be_false
      selected.revalidate!
    end
  end

  it "P05-O08 allows an explicit worktree for bare-configured Git storage" do
    GitOracle.with_repo do |root|
      bare = File.join(File.dirname(root), "bare.git")
      work = File.join(File.dirname(root), "checkout")
      Dir.mkdir_p(work)
      GitOracle.run(root, "clone", "-q", "--bare", root, bare)
      env = {"GIT_DIR" => bare, "GIT_WORK_TREE" => work}
      Git::Repository.from_environment(root, env).bare?.should be_false
      Git::Repository.from_environment(root, env).work_tree.should eq(work)
    end
  end

  it "P05-O09 resolves explicit GIT_COMMON_DIR relative to the per-worktree admin" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "shared.txt"), "from common objects\n")
      GitOracle.run(root, "add", "shared.txt")
      GitOracle.run(root, "commit", "-qm", "base")
      linked = File.join(File.dirname(root), "linked-common")
      GitOracle.run(root, "worktree", "add", "-q", "-b", "common-review", linked)
      admin = File.join(root, ".git", "worktrees", "linked-common")
      env = {"GIT_DIR" => admin, "GIT_COMMON_DIR" => "../repo/.git", "GIT_WORK_TREE" => linked}
      actual = Git::Repository.from_environment(linked, env)
      actual.head.oid.should eq(GitOracle.run(linked, "rev-parse", "HEAD", extra_env: env).stdout.strip)
      actual.read_head_file("shared.txt", max_bytes: 4096).should eq("from common objects\n")
      Git::Location.new(linked, git_dir_option: admin, common_dir_option: "../repo/.git",
        work_tree_option: linked).common.should eq(File.join(root, ".git"))
      actual.revalidate!
      expect_raises(Git::Error) do
        Git::Repository.from_environment(linked, env.merge({"GIT_COMMON_DIR" => "../.."}))
      end
    end
  end

  it "P05-O10 refuses metadata replacement at the same pathname" do
    GitOracle.with_repo do |root|
      store = Git::Repository.new(root)
      gitdir = File.join(root, ".git")
      saved = File.join(root, "backup-gitdir")
      FileUtils.mv(gitdir, saved)
      begin
        FileUtils.cp_r(saved, gitdir)
        expect_raises(Git::Error) { store.revalidate! }
      ensure
        FileUtils.rm_rf(gitdir)
        FileUtils.mv(saved, gitdir)
      end
    end
  end

  it "P05-O11 discovers a nested worktree using a relative .git pointer" do
    GitOracle.with_repo do |root|
      external = File.join(File.dirname(root), "relative-admin")
      GitOracle.run(root, "init", "-q", "--separate-git-dir", external)
      # Git accepts gitdir coordinates relative to the containing worktree.
      File.write(File.join(root, ".git"), "gitdir: ../relative-admin\n")
      sub = File.join(root, "deep", "nested")
      Dir.mkdir_p(sub)
      GitOracle.run(sub, "rev-parse", "--show-toplevel").stdout.strip.should eq(root)
      found = Git::Repository.new(sub, discover: true)
      found.root.should eq(root)
      found.head.symref_target.should eq(GitOracle.run(sub, "symbolic-ref", "HEAD").stdout.strip)
      expect_raises(Git::Error) { Git::Repository.new(sub, discover: true, follow_gitfile: false) }
    end
  end

  it "P05-O12 honors explicit worktree precedence over core.worktree" do
    GitOracle.with_repo do |root|
      other = File.join(File.dirname(root), "other-worktree")
      selected = File.join(File.dirname(root), "selected-worktree")
      Dir.mkdir_p(other)
      Dir.mkdir_p(selected)
      # Relative to the Git administration directory, not the caller cwd.
      GitOracle.run(root, "config", "core.worktree", "../../other-worktree")
      GitOracle.run(root, "rev-parse", "--show-toplevel").stdout.strip.should eq(other)
      env = {"GIT_WORK_TREE" => selected}
      GitOracle.run(root, "rev-parse", "--show-toplevel", extra_env: env).stdout.strip.should eq(selected)
      Git::Repository.from_environment(root, env).root.should eq(selected)
    end
  end

  it "P05-O06 rejects symlinked repository metadata and dangling gitfiles" do
    GitOracle.with_repo do |root|
      outside = File.join(File.dirname(root), "other")
      Dir.mkdir_p(outside)
      FileUtils.mv(File.join(root, ".git"), File.join(outside, "git-dir"))
      File.symlink(File.join(outside, "git-dir"), File.join(root, ".git"))
      expect_raises(Git::Error) { Git::Repository.new(root) }
      expect_raises(Git::Error) { Git::Repository.new(root, discover: true) }
      File.delete(File.join(root, ".git"))
      File.write(File.join(root, ".git"), "gitdir: /nonexistent/host-admin\n")
      expect_raises(Git::Error) { Git::Repository.new(root) }
      # Explicit GIT_DIR overrides a dangling gitfile; implicit discovery
      # must not follow it into arbitrary external storage.
      Git::Repository.new(root, git_dir: File.join(outside, "git-dir")).head.symref_target.should eq("refs/heads/main")
    end
  end
end
