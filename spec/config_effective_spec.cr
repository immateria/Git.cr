require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P06 typed effective configuration and working-tree file modes" do
  it "P06-O45 resolves the last matching boolean with scope, origin and implicit-value evidence" do
    GitOracle.with_repo do |root|
      local = File.join(root, ".git", "config")
      global = File.join(File.dirname(root), "types-global")
      File.write(global, "[test]\n\tflag = off\n\tflag = on\n")
      File.open(local, "a") { |f| f.puts "[test]\n\tflag\n" }
      config = Git::Repository.new(root).config(global_files: [global])
      config.effective_entry?("TEST.flag").not_nil!.scope.should eq(Git::Config::Scope::Local)
      config.effective_entry?("test.flag").not_nil!.value.should be_nil
      config.boolean?("test.flag").should be_true
      config.boolean?("test.absent").should be_nil
      GitOracle.run(root, "config", "--type=bool", "--get", "test.flag", extra_env: {"GIT_CONFIG_GLOBAL" => global}).stdout.strip.should eq("true")
      command = Git::Repository.new(root).config(global_files: [global], command_values: [{"test.flag", "0"}])
      command.boolean?("test.flag").should be_false
      command.effective_entry?("test.flag").not_nil!.scope.should eq(Git::Config::Scope::Command)
      GitOracle.run(root, "-c", "test.flag=0", "config", "--type=bool", "--get", "test.flag", extra_env: {"GIT_CONFIG_GLOBAL" => global}).stdout.strip.should eq("false")
    end
  end

  it "P06-O46 matches Git boolean conversion for textual and bounded numeric forms" do
    GitOracle.with_repo do |root|
      ["", "YES", "off", "-2", "010", "0x10", "0G", "2k", "1g"].each do |raw|
        oracle = GitOracle.run(root, "-c", "test.bool=#{raw}", "config", "--type=bool", "--get", "test.bool")
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.bool", raw}])
        config.boolean?("test.bool").to_s.should eq(oracle.stdout.strip)
      end
      raw_config = File.join(root, ".git", "implicit-config")
      File.write(raw_config, "[test]\n\tbool\n")
      config = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, raw_config)])
      config.boolean?("test.bool").should be_true
      GitOracle.run(root, "config", "--file", raw_config, "--type=bool", "--get", "test.bool").stdout.strip.should eq("true")
    end
  end

  it "P06-O47 matches Git integer base prefixes, units and signed 64-bit values" do
    GitOracle.with_repo do |root|
      ["0", "-2", "+4", "010", "0x10", "2k", "4M", "-5G", "2147483648", "0xFFFFFFFF", "1g"].each do |raw|
        oracle = GitOracle.run(root, "-c", "test.count=#{raw}", "config", "--type=int", "--get", "test.count")
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.count", raw}])
        config.integer?("test.count").to_s.should eq(oracle.stdout.strip)
      end
      Git::Config.load([] of Git::Config::Source).integer?("test.count").should be_nil
    end
  end

  it "P06-O46/47 pins native 0b binary config behavior independently of host libc" do
    # Git 2.47.3 delegates numeric parsing to libc: some hosts reject 0b
    # prefixes, others accept them. The native Crystal contract accepts both
    # binary prefixes deterministically and does not query the Git oracle.
    {"0b0" => 0_i64, "0b11" => 3_i64, "0B101" => 5_i64}.each do |raw, expected|
      config = Git::Config.load([] of Git::Config::Source, commands: [{"test.count", raw}, {"test.flag", raw}])
      config.integer?("test.count").should eq(expected)
      config.boolean?("test.flag").should eq(expected != 0)
    end
  end

  it "P06-O48 preserves boolean tokens but returns bounded integers for bool-or-int" do
    GitOracle.with_repo do |root|
      ["", "YES", "false", "1", "0", "010", "0x10", "2k", "-1M"].each do |raw|
        oracle = GitOracle.run(root, "-c", "test.value=#{raw}", "config", "--type=bool-or-int", "--get", "test.value")
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.value", raw}])
        value = config.boolean_or_integer?("test.value")
        output = case value
                 when Bool  then value.to_s
                 when Int32 then value.to_s
                 else            "MISSING"
                 end
        output.should eq(oracle.stdout.strip)
      end
    end
  end

  it "P06-O49 rejects malformed or overflowing typed values instead of silently taking defaults" do
    GitOracle.with_repo do |root|
      ["invalid", "3 k", "0x", "08", "2147483648", "-5G"].each do |raw|
        oracle = GitOracle.run(root, "-c", "test.flag=#{raw}", "config", "--type=bool", "--get", "test.flag", check: false)
        oracle.success?.should be_false
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.flag", raw}])
        expect_raises(Git::Error) { config.boolean?("test.flag") }
      end
      ["on", "", "3 k", "08", "9223372036854775808", "4Gx"].each do |raw|
        oracle = GitOracle.run(root, "-c", "test.count=#{raw}", "config", "--type=int", "--get", "test.count", check: false)
        oracle.success?.should be_false
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.count", raw}])
        expect_raises(Git::Error) { config.integer?("test.count") }
      end
    end
  end

  it "P06-O52 prevents Int128 suffix overflow and unsigned-like range bypass" do
    GitOracle.with_repo do |root|
      ["170141183460469231731687303715884105727k", "9223372036854775808", "-9223372036854775808", "-9223372036854775809"].each do |raw|
        GitOracle.run(root, "-c", "test.count=#{raw}", "config", "--type=int", "--get", "test.count", check: false).success?.should be_false
        config = Git::Config.load([] of Git::Config::Source, commands: [{"test.count", raw}])
        expect_raises(Git::Error, /range/) { config.integer?("test.count") }
      end
      config = Git::Config.load([] of Git::Config::Source, commands: [{"test.count", "-9223372036854775807"}])
      config.integer?("test.count").should eq(-Int64::MAX)
      GitOracle.run(root, "-c", "test.count=-9223372036854775807", "config", "--type=int", "--get", "test.count").stdout.strip.should eq((-Int64::MAX).to_s)
    end
  end

  it "P06-O53 rejects invalid effective core.filemode without suppressing a change" do
    GitOracle.with_repo do |root|
      file = File.join(root, "script.sh")
      File.write(file, "echo stable\n")
      File.chmod(file, 0o644)
      GitOracle.run(root, "add", "script.sh")
      GitOracle.run(root, "commit", "-qm", "baseline")
      File.chmod(file, 0o755)
      store = Git::Repository.new(root)
      invalid = store.config(command_values: [{"core.filemode", "invalid"}])
      GitOracle.run(root, "-c", "core.filemode=invalid", "status", "--porcelain", check: false).success?.should be_false
      expect_raises(Git::Error) { store.working_changes(max_bytes: 16_384, limit: 5, config: invalid, include_untracked: false) }
      expect_raises(Git::Error) { store.working_file("script.sh", max_bytes: 16_384, config: invalid) }
      # The existing raw default remains unchanged; only an explicitly
      # supplied, resolved configuration can change how modes are compared.
      raw = store.working_changes(max_bytes: 16_384, limit: 5, include_untracked: false)
      raw.map(&.status).should eq(["modified"])
    end
  end

  it "P06-O50 applies explicit effective core.filemode to native status and working diffs" do
    GitOracle.with_repo do |root|
      file = File.join(root, "script.sh")
      File.write(file, "echo fixed\n")
      File.chmod(file, 0o644)
      GitOracle.run(root, "add", "script.sh")
      GitOracle.run(root, "commit", "-qm", "baseline")
      File.chmod(file, 0o755)
      store = Git::Repository.new(root)
      config_true = store.config(command_values: [{"core.filemode", "true"}])
      config_false = store.config(command_values: [{"core.filemode", "false"}])
      with_mode = store.working_changes(max_bytes: 128 * 1024, limit: 20, include_untracked: false, config: config_true)
      without_mode = store.working_changes(max_bytes: 128 * 1024, limit: 20, include_untracked: false, config: config_false)
      with_mode.map(&.path).should eq(["script.sh"])
      without_mode.should be_empty
      store.working_file("script.sh", max_bytes: 128 * 1024, config: config_true).should_not be_nil
      store.working_file("script.sh", max_bytes: 128 * 1024, config: config_false).should be_nil
      GitOracle.run(root, "-c", "core.filemode=true", "status", "--porcelain=v1", "--untracked-files=no").stdout.should contain("script.sh")
      GitOracle.run(root, "-c", "core.filemode=false", "status", "--porcelain=v1", "--untracked-files=no").stdout.should be_empty
      File.write(file, "echo changed\n")
      changed = store.working_changes(max_bytes: 128 * 1024, limit: 20, include_untracked: false, config: config_false)
      changed.map(&.status).should eq(["modified"])
      store.working_file("script.sh", max_bytes: 128 * 1024, config: config_false).should_not be_nil
    end
  end

  it "P06-O51 uses worktree and command scope when evaluating effective core.filemode" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "config", "--local", "extensions.worktreeConfig", "true")
      GitOracle.run(root, "config", "--local", "core.filemode", "true")
      GitOracle.run(root, "config", "--worktree", "core.filemode", "false")
      config = Git::Repository.new(root).config
      config.boolean?("core.filemode").should be_false
      config.effective_entry?("core.filemode").not_nil!.scope.should eq(Git::Config::Scope::Worktree)
      GitOracle.run(root, "config", "--type=bool", "--get", "core.filemode").stdout.strip.should eq("false")
      forced = Git::Repository.new(root).config(command_values: [{"core.filemode", "true"}])
      forced.boolean?("core.filemode").should be_true
      forced.effective_entry?("core.filemode").not_nil!.scope.should eq(Git::Config::Scope::Command)
      GitOracle.run(root, "-c", "core.filemode=true", "config", "--type=bool", "--get", "core.filemode").stdout.strip.should eq("true")
    end
  end
end
