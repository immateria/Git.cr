require "spec"
require "../src/git"
require "./support/git_oracle"

# Oracle ownership changes run only when the test process is root; the
# deterministic native policy expectations also run as an ordinary user.
private def git_unsafe_owner_fixture(&block : (String, Bool) ->)
  GitOracle.with_repo do |root|
    foreign = File.info(root).owner_id == "0"
    if foreign
      status = Process.run("/usr/bin/chown", ["-R", "54321:54321", root])
      raise "fixture chown failed" unless status.success?
    end
    begin
      yield root, foreign
    ensure
      if foreign
        status = Process.run("/usr/bin/chown", ["-R", "0:0", root])
        raise "fixture owner restore failed" unless status.success?
      end
    end
  end
end

private def safe_config_file(root : String, name : String, body : String) : String
  path = File.join(File.dirname(root), name)
  File.write(path, body)
  path
end

describe "P06 Git protected safe.directory ownership admission" do
  it "P06-O19 admits a repository owned by the caller but rejects foreign ownership by default" do
    GitOracle.with_repo do |root|
      store = Git::Repository.new(root)
      native_owner = File.info(root).owner_id
      store.safe_directory?(Git::Repository::Admission::Identity.new(native_owner)).should be_true
      store.safe_directory?(Git::Repository::Admission::Identity.new("999991")).should be_false
      expect_raises(Git::Error, /ownership|unsafe/) do
        store.require_safe_directory!(Git::Repository::Admission::Identity.new("999991"))
      end
    end
    git_unsafe_owner_fixture do |root, foreign|
      if foreign
        store = Git::Repository.new(root)
        store.safe_directory?(Git::Repository::Admission::Identity.new("0")).should be_false
        GitOracle.run(root, "status", "--porcelain", check: false).success?.should be_false
      end
    end
  end

  it "P06-O20 ignores local safe.directory but allows protected global and command entries" do
    git_unsafe_owner_fixture do |root, foreign|
      store = Git::Repository.new(root)
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      File.open(File.join(root, ".git", "config"), "a") do |file|
        file.puts "[safe]\n directory = #{root}"
      end
      store.safe_directory?(identity).should be_false
      if foreign
        GitOracle.run(root, "status", "--porcelain", check: false).success?.should be_false
      end
      global = safe_config_file(root, "safe-global", "[safe]\n directory = #{root}\n")
      store.safe_directory?(identity, global_files: [global]).should be_true
      store.safe_directory?(identity, command_values: [{"safe.directory", root}]).should be_true
      if foreign
        GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_true
        GitOracle.run(root, "-c", "safe.directory=#{root}", "status", "--porcelain").success?.should be_true
      end
    end
  end

  it "P06-O21 respects multivalue order, wildcard, reset and protected source precedence" do
    git_unsafe_owner_fixture do |root, foreign|
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      store = Git::Repository.new(root)
      system = safe_config_file(root, "safe-system", "[safe]\n directory = *\n")
      global = safe_config_file(root, "safe-global", "[safe]\n directory =\n directory = /unrelated\n")
      store.safe_directory?(identity, system_files: [system]).should be_true
      store.safe_directory?(identity, system_files: [system], global_files: [global]).should be_false
      store.safe_directory?(identity, system_files: [system], global_files: [global],
        command_values: [{"safe.directory", root}]).should be_true
      if foreign
        GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_NOSYSTEM" => "0", "GIT_CONFIG_SYSTEM" => system}).success?.should be_true
        GitOracle.run(root, "status", "--porcelain", check: false,
          extra_env: {"GIT_CONFIG_NOSYSTEM" => "0", "GIT_CONFIG_SYSTEM" => system, "GIT_CONFIG_GLOBAL" => global}).success?.should be_false
        GitOracle.run(root, "-c", "safe.directory=#{root}", "status", "--porcelain",
          extra_env: {"GIT_CONFIG_NOSYSTEM" => "0", "GIT_CONFIG_SYSTEM" => system, "GIT_CONFIG_GLOBAL" => global}).success?.should be_true
      end
    end
  end

  it "P06-O22 matches canonical paths and directory-star descendants but not the directory itself" do
    git_unsafe_owner_fixture do |root, foreign|
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      store = Git::Repository.new(root)
      parent = File.dirname(root)
      allow_children = safe_config_file(root, "safe-desc", "[safe]\n directory = #{parent}/*\n")
      allow_self_children = safe_config_file(root, "safe-self-desc", "[safe]\n directory = #{root}/*\n")
      store.safe_directory?(identity, global_files: [allow_children]).should be_true
      store.safe_directory?(identity, global_files: [allow_self_children]).should be_false
      store.safe_directory?(identity, command_values: [{"safe.directory", "./relative"}]).should be_false
      if foreign
        GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => allow_children}).success?.should be_true
        GitOracle.run(root, "status", "--porcelain", check: false,
          extra_env: {"GIT_CONFIG_GLOBAL" => allow_self_children}).success?.should be_false
      end
    end
  end

  it "P06-O23 expands explicit HOME and accepts canonical aliases without inheriting process HOME" do
    git_unsafe_owner_fixture do |root, foreign|
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      store = Git::Repository.new(root)
      home = File.dirname(root)
      global = safe_config_file(root, "safe-home", "[safe]\n directory = ~/#{File.basename(root)}\n")
      store.safe_directory?(identity, global_files: [global]).should be_false
      store.safe_directory?(identity, global_files: [global], home: home).should be_true
      alias_path = File.join(home, "repo-alias")
      File.symlink(root, alias_path)
      alias_cfg = safe_config_file(root, "safe-alias", "[safe]\n directory = #{alias_path}\n")
      store.safe_directory?(identity, global_files: [alias_cfg]).should be_true
      if foreign
        GitOracle.run(root, "status", "--porcelain", extra_env: {"HOME" => home, "GIT_CONFIG_GLOBAL" => global}).success?.should be_true
        GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => alias_cfg}).success?.should be_true
      end
    end
  end

  it "P06-O24 allows a host-supplied SUDO_UID only for a root identity" do
    git_unsafe_owner_fixture do |root, foreign|
      owner = File.info(root).owner_id
      identity = Git::Repository::Admission::Identity.new("0", sudo_uid: owner)
      Git::Repository.new(root).safe_directory?(identity).should be_true
      Git::Repository.new(root).safe_directory?(Git::Repository::Admission::Identity.new("123", sudo_uid: owner)).should be_false unless owner == "123"
      if foreign
        ["000#{owner}", "+#{owner}", " #{owner}"].each do |numeric|
          Git::Repository.new(root).safe_directory?(Git::Repository::Admission::Identity.new("0", sudo_uid: numeric)).should be_true
          GitOracle.run(root, "status", "--porcelain", extra_env: {"SUDO_UID" => numeric}).success?.should be_true
        end
        ["#{owner}junk", "-1", "4294967296", "0xD431"].each do |invalid|
          Git::Repository.new(root).safe_directory?(Git::Repository::Admission::Identity.new("0", sudo_uid: invalid)).should be_false
          GitOracle.run(root, "status", "--porcelain", check: false,
            extra_env: {"SUDO_UID" => invalid}).success?.should be_false
        end
      end
    end
  end
end

describe "P06 owner-path and checked-opening coverage" do
  it "P06-O25 checks worktree and .git owners independently, and offers a checked constructor" do
    GitOracle.with_repo do |root|
      owner = File.info(root).owner_id
      foreign_id = owner == "0" ? "54321" : "999991"
      identity = Git::Repository::Admission::Identity.new(owner)
      Git::Repository.open_with_ownership_check(root, identity: identity).head.symref_target.should eq("refs/heads/main")
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(root, identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
      if owner == "0"
        git_dir = File.join(root, ".git")
        status = Process.run("/usr/bin/chown", ["54321:54321", git_dir])
        raise "fixture chown failed" unless status.success?
        begin
          Git::Repository.new(root).safe_directory?(identity).should be_false
          GitOracle.run(root, "status", "--porcelain", check: false).success?.should be_false
          allow = safe_config_file(root, "safe-gitowner", "[safe]\n directory = #{root}\n")
          Git::Repository.open_with_ownership_check(root, identity: identity, global_files: [allow]).safe_directory?(identity,
            global_files: [allow]).should be_true
          GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => allow}).success?.should be_true
        ensure
          Process.run("/usr/bin/chown", ["0:0", git_dir])
        end
      end
    end
  end

  it "P06-O26 compares bare-repository ownership admission against Git" do
    GitOracle.with_repo do |root|
      bare = File.join(File.dirname(root), "store.git")
      GitOracle.run(root, "init", "--bare", "-q", bare)
      owner = File.info(bare).owner_id
      if owner == "0"
        status = Process.run("/usr/bin/chown", ["-R", "54321:54321", bare])
        raise "fixture chown failed" unless status.success?
      end
      begin
        identity = Git::Repository::Admission::Identity.new(owner == "0" ? "0" : "999991")
        store = Git::Repository.new(bare)
        store.bare?.should be_true
        store.safe_directory?(identity).should be_false
        allow = safe_config_file(root, "bare-allow", "[safe]\n directory = #{bare}\n")
        store.safe_directory?(identity, global_files: [allow]).should be_true
        if owner == "0"
          GitOracle.run(bare, "rev-parse", "--git-dir", check: false).success?.should be_false
          GitOracle.run(bare, "rev-parse", "--git-dir", extra_env: {"GIT_CONFIG_GLOBAL" => allow}).success?.should be_true
        end
      ensure
        Process.run("/usr/bin/chown", ["-R", "0:0", bare]) if owner == "0"
      end
    end
  end

  it "P06-O27 checks a linked worktree .git pointer file independently" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "tracked.txt"), "first\n")
      GitOracle.run(root, "add", "tracked.txt")
      GitOracle.run(root, "commit", "-qm", "initial")
      linked = File.join(File.dirname(root), "linked")
      GitOracle.run(root, "worktree", "add", "-qb", "other", linked)
      store = Git::Repository.new(linked)
      owner = File.info(linked).owner_id
      identity = Git::Repository::Admission::Identity.new(owner)
      store.safe_directory?(identity).should be_true
      if owner == "0"
        marker = File.join(linked, ".git")
        status = Process.run("/usr/bin/chown", ["54321:54321", marker])
        raise "fixture chown failed" unless status.success?
        begin
          store.safe_directory?(identity).should be_false
          GitOracle.run(linked, "status", "--porcelain", check: false).success?.should be_false
          allow = safe_config_file(root, "linked-allow", "[safe]\n directory = #{linked}\n")
          store.safe_directory?(identity, global_files: [allow]).should be_true
          GitOracle.run(linked, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => allow}).success?.should be_true
        ensure
          Process.run("/usr/bin/chown", ["0:0", marker])
        end
      end
    end
  end

  it "P06-O28 supports caller-supplied Git prefix interpolation without inventing a host installation prefix" do
    git_unsafe_owner_fixture do |root, foreign|
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      store = Git::Repository.new(root)
      prefix = File.dirname(root)
      cfg = safe_config_file(root, "safe-prefix", "[safe]\n directory = %(prefix)/#{File.basename(root)}\n")
      store.safe_directory?(identity, global_files: [cfg]).should be_false
      store.safe_directory?(identity, global_files: [cfg], git_prefix: prefix).should be_true
    end
  end
end

describe "P06 early ownership gate before repository configuration" do
  it "P06-O29 refuses foreign ownership before interpreting malformed core config" do
    GitOracle.with_repo do |root|
      config = File.join(root, ".git", "config")
      File.open(config, "a") { |file| file.puts "[core]\n bare = not-a-bool" }
      foreign_id = File.info(root).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(root,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
      expect_raises(Git::Error, /invalid Git core.bare/) do
        Git::Repository.open_with_ownership_check(root,
          identity: Git::Repository::Admission::Identity.new(File.info(root).owner_id))
      end
    end
  end

  it "P06-O30 refuses foreign ownership before interpreting malformed format extensions" do
    GitOracle.with_repo do |root|
      config = File.join(root, ".git", "config")
      File.open(config, "a") { |file| file.puts "[extensions]\n objectFormat = invalid" }
      foreign_id = File.info(root).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(root,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
      expect_raises(Git::Error, /unsupported Git object format/) do
        Git::Repository.open_with_ownership_check(root,
          identity: Git::Repository::Admission::Identity.new(File.info(root).owner_id))
      end
    end
  end

  it "P06-O31 handles foreign-owned bare repositories before core config interpretation" do
    GitOracle.with_repo do |root|
      bare = File.join(File.dirname(root), "bare.git")
      GitOracle.run(root, "init", "--bare", "-q", bare)
      config = File.join(bare, "config")
      File.open(config, "a") { |file| file.puts "[core]\n bare = not-a-bool" }
      foreign_id = File.info(bare).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(bare,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
      expect_raises(Git::Error, /invalid Git core.bare/) do
        Git::Repository.open_with_ownership_check(bare,
          identity: Git::Repository::Admission::Identity.new(File.info(bare).owner_id))
      end
    end
  end
end

describe "P06 early safe-directory protected context" do
  it "P06-O32 accepts unconditional protected includes but not repository-dependent conditional includes" do
    git_unsafe_owner_fixture do |root, foreign|
      identity = Git::Repository::Admission::Identity.new(foreign ? "0" : "999991")
      included = safe_config_file(root, "included-safe", "[safe]\n directory = #{root}\n")
      global = safe_config_file(root, "safe-include", "[include]\n path = #{included}\n")
      Git::Repository.open_with_ownership_check(root, identity: identity, global_files: [global]).safe_directory?(identity,
        global_files: [global]).should be_true
      if foreign
        GitOracle.run(root, "status", "--porcelain", extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_true
      end
      ["gitdir:#{root}/.git", "onbranch:main"].each do |condition|
        File.write(global, %([includeIf "#{condition}"]\n path = #{included}\n))
        Git::Repository.new(root).safe_directory?(identity, global_files: [global]).should be_false
        expect_raises(Git::Error, /ownership/) do
          Git::Repository.open_with_ownership_check(root, identity: identity, global_files: [global])
        end
        if foreign
          GitOracle.run(root, "status", "--porcelain", check: false,
            extra_env: {"GIT_CONFIG_GLOBAL" => global}).success?.should be_false
        end
      end
    end
  end

  it "P06-O33 refuses malformed config when ownership is untrusted, then reports malformed config after a protected exception" do
    GitOracle.with_repo do |root|
      foreign_id = File.info(root).owner_id == "0" ? "54321" : "0"
      config = File.join(root, ".git", "config")
      File.open(config, "a") { |file| file.puts "[core]\n bare = invalid" }
      globals = safe_config_file(root, "safe-early-allow", "[safe]\n directory = #{root}\n")
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(root, identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
      expect_raises(Git::Error, /invalid Git core.bare/) do
        Git::Repository.open_with_ownership_check(root,
          identity: Git::Repository::Admission::Identity.new(foreign_id), global_files: [globals])
      end
    end
  end
end

describe "P06 checked-selection traversal and revalidation" do
  it "P06-O34 admits ownership before config in nested discovery and external Git directories" do
    GitOracle.with_repo do |root|
      nested = File.join(root, "nested", "deeper")
      Dir.mkdir_p(nested)
      config = File.join(root, ".git", "config")
      File.open(config, "a") { |file| file.puts "[core]\n bare = invalid" }
      foreign_id = File.info(root).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(nested, discover: true,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
    end
    GitOracle.with_repo do |root|
      external = File.join(File.dirname(root), "external.git")
      separated = File.join(File.dirname(root), "separated")
      Dir.mkdir_p(separated)
      GitOracle.run(root, "init", "-q", "--separate-git-dir", external, separated)
      File.open(File.join(external, "config"), "a") { |file| file.puts "[core]\n bare = invalid" }
      foreign_id = File.info(root).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(separated, git_dir: external,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
    end
  end

  it "P06-O35 checks linked worktree owner before interpreting shared config" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, "tracked.txt"), "first\n")
      GitOracle.run(root, "add", "tracked.txt")
      GitOracle.run(root, "commit", "-qm", "initial")
      linked = File.join(File.dirname(root), "linked")
      GitOracle.run(root, "worktree", "add", "-qb", "other", linked)
      File.open(File.join(root, ".git", "config"), "a") { |file| file.puts "[core]\n bare = invalid" }
      foreign_id = File.info(linked).owner_id == "0" ? "54321" : "0"
      expect_raises(Git::Error, /ownership/) do
        Git::Repository.open_with_ownership_check(linked,
          identity: Git::Repository::Admission::Identity.new(foreign_id))
      end
    end
  end

  it "P06-O36 rechecks admission if a selected repository changes ownership" do
    GitOracle.with_repo do |root|
      owner = File.info(root).owner_id
      checked = Git::Repository.open_with_ownership_check(root,
        identity: Git::Repository::Admission::Identity.new(owner))
      checked.revalidate!
      if owner == "0"
        status = Process.run("/usr/bin/chown", ["54321:54321", root])
        raise "fixture chown failed" unless status.success?
        begin
          expect_raises(Git::Error, /ownership/) { checked.revalidate! }
        ensure
          status = Process.run("/usr/bin/chown", ["0:0", root])
          raise "fixture chown restore failed" unless status.success?
        end
      end
    end
  end
end
