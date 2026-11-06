require "spec"
require "../src/git"
require "./support/git_oracle"

# P06: bare-repository selection is a protected-config admission decision,
# separate from dubious-ownership admission and the adapter's tool policy.
private def bare_fixture(format : String = "sha1", &block : (String, String) ->)
  GitOracle.with_repo(format: format) do |root|
    bare = File.join(File.dirname(root), "bare.git")
    GitOracle.run(root, "init", "-q", "--bare", "--object-format=#{format}", bare)
    yield root, bare
  end
end

private def bare_global(root : String, value : String) : String
  config = File.join(File.dirname(root), "protected-bare-config")
  File.write(config, "[safe]\n bareRepository = #{value}\n")
  config
end

describe "P06 protected safe.bareRepository" do
  it "P06-O37 preserves Git 2.x default all for bare SHA-1 and SHA-256" do
    ["sha1", "sha256"].each do |format|
      bare_fixture(format) do |root, bare|
        GitOracle.run(bare, "rev-parse", "--absolute-git-dir").stdout.strip.should eq(bare)
        Git::Repository.new(bare).bare?.should be_true
        Git::Repository.open_with_bare_repository_check(bare).bare?.should be_true
      end
    end
  end

  it "P06-O38 rejects implicit bare selection, including nested discovery, while explicit GIT_DIR works" do
    bare_fixture do |root, bare|
      global = bare_global(root, "explicit")
      env = {"GIT_CONFIG_GLOBAL" => global}
      GitOracle.run(bare, "rev-parse", "--absolute-git-dir", check: false,
        extra_env: env).success?.should be_false
      nested = File.join(bare, "nested", "child")
      Dir.mkdir_p(nested)
      GitOracle.run(nested, "rev-parse", "--absolute-git-dir", check: false,
        extra_env: env).success?.should be_false
      GitOracle.run(root, "--git-dir=#{bare}", "rev-parse", "--absolute-git-dir",
        extra_env: env).stdout.strip.should eq(bare)
      GitOracle.run(root, "rev-parse", "--absolute-git-dir",
        extra_env: env.merge({"GIT_DIR" => bare})).stdout.strip.should eq(bare)
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(bare, global_files: [global])
      end
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(nested, global_files: [global], discover: true)
      end
      Git::Repository.open_with_bare_repository_check(root, git_dir: bare,
        global_files: [global]).bare?.should be_true
      Git::Repository.open_with_bare_repository_check(bare, git_dir: bare,
        global_files: [global]).bare?.should be_true
    end
  end

  it "P06-O39 trusts only protected origins, with system/global/command precedence" do
    bare_fixture do |root, bare|
      env = {"GIT_CONFIG_GLOBAL" => bare_global(root, "explicit")}
      File.open(File.join(bare, "config"), "a") do |stream|
        stream.puts "[safe]\n bareRepository = all"
      end
      GitOracle.run(bare, "rev-parse", "--git-dir", check: false,
        extra_env: env).success?.should be_false
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(bare, global_files: [env["GIT_CONFIG_GLOBAL"]])
      end
      GitOracle.run(bare, "-c", "safe.bareRepository=all", "rev-parse", "--git-dir",
        extra_env: env).success?.should be_true
      Git::Repository.open_with_bare_repository_check(bare, global_files: [env["GIT_CONFIG_GLOBAL"]],
        command_values: [{"safe.bareRepository", "all"}]).bare?.should be_true
      system = File.join(File.dirname(root), "bare-system")
      File.write(system, "[safe]\n bareRepository = explicit\n")
      global = bare_global(root, "all")
      Git::Repository.open_with_bare_repository_check(bare, system_files: [system],
        global_files: [global]).bare?.should be_true
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(bare, system_files: [system],
          global_files: [global], command_values: [{"safe.bareRepository", "explicit"}])
      end
    end
  end

  it "P06-O40 expands trusted unconditional includes but does not use repository-dependent includes for admission" do
    bare_fixture do |root, bare|
      include_path = File.join(File.dirname(root), "bare-included")
      File.write(include_path, "[safe]\n bareRepository = explicit\n")
      global = File.join(File.dirname(root), "bare-global-include")
      File.write(global, "[include]\n path = #{include_path}\n")
      GitOracle.run(bare, "rev-parse", "--git-dir", check: false,
        extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_false
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(bare, global_files: [global])
      end
      File.write(global, "[includeIf \"gitdir:#{bare}/\"]\n path = #{include_path}\n")
      Git::Repository.open_with_bare_repository_check(bare, global_files: [global]).bare?.should be_true
      GitOracle.run(bare, "rev-parse", "--git-dir",
        extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_true
    end
  end

  it "P06-O41 ignores bare-policy refusal for ordinary worktrees and explicit Git directories" do
    bare_fixture do |root, bare|
      global = bare_global(root, "explicit")
      GitOracle.run(root, "rev-parse", "--absolute-git-dir",
        extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_true
      Git::Repository.open_with_bare_repository_check(root, global_files: [global]).bare?.should be_false
      Git::Repository.open_with_bare_repository_check(root, git_dir: bare,
        work_tree: root, global_files: [global]).bare?.should be_false
      Git::Repository.open_with_bare_repository_check(bare, git_dir: bare,
        global_files: [global]).bare?.should be_true
      GitOracle.run(bare, "rev-parse", "--git-dir", check: false,
        extra_env: {"GIT_CONFIG_GLOBAL" => global, "GIT_WORK_TREE" => root}).success?.should be_false
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_bare_repository_check(bare, work_tree: root,
          global_files: [global])
      end
    end
  end

  it "P06-O42 validates protected enum values only on implicit bare selection" do
    bare_fixture do |root, bare|
      global = bare_global(root, "invalid")
      GitOracle.run(bare, "rev-parse", "--git-dir", check: false,
        extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_false
      expect_raises(Git::Error, /safe.bareRepository/) do
        Git::Repository.open_with_bare_repository_check(bare, global_files: [global])
      end
      Git::Repository.open_with_bare_repository_check(root, git_dir: bare,
        global_files: [global]).bare?.should be_true
    end
  end

  it "P06-O43 rechecks protected policy on an already-opened bare repository" do
    bare_fixture do |root, bare|
      global = bare_global(root, "all")
      store = Git::Repository.open_with_bare_repository_check(bare, global_files: [global])
      store.revalidate!
      File.write(global, "[safe]\n bareRepository = explicit\n")
      expect_raises(Git::Error, /bare/) { store.revalidate! }
      File.write(global, "[safe]\n bareRepository = all\n")
      store.revalidate!
    end
  end

  it "P06-O44 honors safe.bareRepository alongside checked ownership without broadening access" do
    bare_fixture do |root, bare|
      uid = File.info(bare).owner_id
      global = bare_global(root, "explicit")
      expect_raises(Git::Error, /bare/) do
        Git::Repository.open_with_ownership_check(bare,
          identity: Git::Repository::Admission::Identity.new(uid), global_files: [global])
      end
      Git::Repository.open_with_ownership_check(bare, identity: Git::Repository::Admission::Identity.new(uid),
        git_dir: bare, global_files: [global]).bare?.should be_true
    end
  end
end
