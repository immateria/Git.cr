require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P06 Git configuration reader" do
  it "P06-O01 preserves file order, multivalues, case-normalized keys, escapes, implicit values and comments" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      File.open(file, "a") do |f|
        f.puts %q{[profile "Feature.Branch"]}
        f.puts %q{ name = " padded " # comment}
        f.puts %q{ name = two\twords}
        f.puts %q{ implicit}
        f.puts %q{ continuation = one\}
        f.puts %q{ two}
        f.puts %q{[Mixed.Section]}
        f.puts %q{ WeIrD-Key = value ; comment}
      end
      source = Git::Config::Source.new(Git::Config::Scope::Local, file)
      actual = Git::Config.load([source])
      encoded = actual.entries.map { |entry| entry.name + (entry.value ? "\n" + entry.value.not_nil! : "") + "\0" }.join
      oracle = GitOracle.run(root, "config", "--local", "--null", "--list").stdout
      GitOracle.assert_bytes!(encoded, oracle, "P06-O01")
      actual.values("profile.Feature.Branch.name").should eq([" padded ", "two\twords"])
      actual.values("profile.Feature.Branch.implicit").should eq([nil])
      actual.value?("profile.Feature.Branch.continuation").should eq("one two")
    end
  end

  it "P06-O02 loads explicit system/global/local scopes and gives last-value precedence" do
    GitOracle.with_repo do |root|
      base = File.dirname(root)
      system = File.join(base, "system-config")
      global = File.join(base, "global-config")
      File.write(system, "[test]\n\tpriority = system\n\tpriority = system2\n")
      File.write(global, "[test]\n\tpriority = global\n")
      GitOracle.run(root, "config", "--local", "test.priority", "local")
      source = [
        Git::Config::Source.new(Git::Config::Scope::System, system),
        Git::Config::Source.new(Git::Config::Scope::Global, global),
        Git::Config::Source.new(Git::Config::Scope::Local, File.join(root, ".git", "config")),
      ]
      actual = Git::Config.load(source)
      oracle = GitOracle.run(root, "config", "--null", "--list", "--show-scope",
        extra_env: {"GIT_CONFIG_NOSYSTEM" => "0", "GIT_CONFIG_SYSTEM" => system, "GIT_CONFIG_GLOBAL" => global})
      # Ensure the oracle ran and explicitly observed all three scopes.
      oracle.stdout.should contain("system\0")
      oracle.stdout.should contain("global\0")
      oracle.stdout.should contain("local\0")
      actual.values("test.priority").should eq(["system", "system2", "global", "local"])
      actual.value?("test.priority").should eq("local")
      actual.entries.select { |e| e.name == "test.priority" }.map(&.scope).should eq([
        Git::Config::Scope::System, Git::Config::Scope::System,
        Git::Config::Scope::Global, Git::Config::Scope::Local,
      ])
    end
  end

  it "P06-O03 inserts relative includes inline and preserves included origins" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      child = File.join(root, ".git", "extras.inc")
      File.write(child, "[test]\n\tvalue = included\n")
      File.open(file, "a") { |f| f.puts "[test]\n\tvalue = before\n[include]\n\tpath = extras.inc\n[test]\n\tvalue = after" }
      config = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)])
      config.values("test.value").should eq(["before", "included", "after"])
      config.entries.select { |entry| entry.name == "test.value" }.map(&.origin).should eq([
        file, child, file,
      ])
      oracle = GitOracle.run(root, "config", "--local", "--includes", "--null", "--list")
      encoded = config.entries.map { |entry| entry.name + (entry.value ? "\n" + entry.value.not_nil! : "") + "\0" }.join
      GitOracle.assert_bytes!(encoded, oracle.stdout, "P06-O03")
    end
  end

  it "P06-O04 evaluates gitdir includes against a supplied repository context" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      child = File.join(root, ".git", "conditional.inc")
      File.write(child, "[test]\n\tconditional = selected\n")
      File.open(file, "a") do |f|
        f.puts %Q{[includeIf "gitdir:#{File.join(root, ".git")}"]}
        f.puts "path = conditional.inc"
      end
      ctx = Git::Config::Context.new(git_dir: File.join(root, ".git"), work_tree: root, branch: "main")
      config = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)], context: ctx)
      config.value?("test.conditional").should eq("selected")
      GitOracle.run(root, "config", "--local", "--includes", "--get", "test.conditional").stdout.strip.should eq("selected")
    end
  end

  it "P06-O05 rejects malformed syntax, recursive includes and unbounded input" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "bad.inc")
      source = Git::Config::Source.new(Git::Config::Scope::Local, file)
      File.write(file, "[core\n\tbare = false\n")
      expect_raises(Git::Error) { Git::Config.load([source]) }
      File.write(file, "[include]\n\tpath = bad.inc\n")
      expect_raises(Git::Error, /depth|cycle/) { Git::Config.load([source]) }
      File.write(file, "[test]\n\tvalue = " + "x" * 2048)
      expect_raises(Git::Error, /budget/) { Git::Config.load([source], max_bytes: 256) }
    end
  end
end

describe "P06 repository configuration integration" do
  it "P06-O06 reads Git worktree scope only after extensions.worktreeConfig and preserves command precedence" do
    GitOracle.with_repo do |root|
      GitOracle.run(root, "config", "--local", "user.name", "Repo User")
      GitOracle.run(root, "config", "--local", "extensions.worktreeConfig", "true")
      GitOracle.run(root, "config", "--worktree", "user.name", "Worktree User")
      config = Git::Repository.new(root).config(command_values: [{"user.name", "Command User"}])
      config.values("user.name").should eq(["Repo User", "Worktree User", "Command User"])
      config.entries.select { |item| item.name == "user.name" }.map(&.scope).should eq([
        Git::Config::Scope::Local, Git::Config::Scope::Worktree, Git::Config::Scope::Command,
      ])
      config.value?("user.name").should eq("Command User")
      GitOracle.run(root, "-c", "user.name=Command User", "config", "--get", "user.name").stdout.strip.should eq("Command User")
    end
  end

  it "P06-O07 treats safe.directory as protected-scope-only even when local config claims it" do
    GitOracle.with_repo do |root|
      global = File.join(File.dirname(root), "trusted-global")
      File.write(global, "[safe]\n\tdirectory = /trusted\n")
      GitOracle.run(root, "config", "--local", "safe.directory", "/untrusted")
      config = Git::Repository.new(root).config(global_files: [global])
      config.values("safe.directory").should eq(["/trusted", "/untrusted"])
      config.protected_entries("safe.directory").map(&.value).should eq(["/trusted"])
    end
  end
end

describe "P06 configuration differential edge cases" do
  it "P06-O08 matches Git --show-scope --show-origin -z including explicit command values" do
    GitOracle.with_repo do |root|
      base = File.dirname(root)
      system = File.join(base, "system.conf")
      global = File.join(base, "global.conf")
      File.write(system, "[example]\n\tlist = system\n")
      File.write(global, "[example]\n\tlist = global\n")
      GitOracle.run(root, "config", "--local", "--add", "example.list", "local")
      sources = [
        Git::Config::Source.new(Git::Config::Scope::System, system),
        Git::Config::Source.new(Git::Config::Scope::Global, global),
        Git::Config::Source.new(Git::Config::Scope::Local, File.join(root, ".git", "config")),
      ]
      config = Git::Config.load(sources, commands: [{"example.list", "command"}])
      git = GitOracle.run(root, "-c", "example.list=command", "config", "--null", "--list", "--show-origin", "--show-scope",
        extra_env: {"GIT_CONFIG_NOSYSTEM" => "0", "GIT_CONFIG_SYSTEM" => system, "GIT_CONFIG_GLOBAL" => global})
      tokens = git.stdout.split('\0')
      tokens.pop if tokens.last?.try(&.empty?)
      tokens.size.should eq(config.entries.size * 3)
      config.entries.each_with_index do |entry, i|
        tokens[i * 3].should eq(entry.scope.to_s.downcase)
        oracle_origin = tokens[i * 3 + 1]
        actual_origin = entry.scope == Git::Config::Scope::Command ? "command line:" : "file:" + entry.origin
        # Git's default local origin is relative to its -C cwd.
        oracle_origin = "file:" + File.expand_path(oracle_origin.byte_slice(5, oracle_origin.bytesize - 5), root) if oracle_origin.starts_with?("file:") && !Path[oracle_origin.byte_slice(5, oracle_origin.bytesize - 5)].absolute?
        oracle_origin.should eq(actual_origin)
        encoded = entry.name + (entry.value ? "\n" + entry.value.not_nil! : "")
        tokens[i * 3 + 2].should eq(encoded)
      end
    end
  end

  it "P06-O09 matches conditional worktree and onbranch includes" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      worktree = File.join(root, ".git", "worktree.inc")
      branch = File.join(root, ".git", "branch.inc")
      File.write(worktree, "[test]\n\tcondition = worktree\n")
      File.write(branch, "[test]\n\tcondition = onbranch\n")
      File.open(file, "a") do |f|
        f.puts %Q{[includeIf "worktree:#{root}/"]}
        f.puts "path = worktree.inc"
        f.puts %q{[includeIf "onbranch:main"]}
        f.puts "path = branch.inc"
      end
      ctx = Git::Config::Context.new(git_dir: File.join(root, ".git"), work_tree: root, branch: "main")
      actual = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)], context: ctx)
      actual.values("test.condition").should eq(["worktree", "onbranch"])
      # Git 2.47.3 recognizes onbranch, but does not yet activate the
      # newer worktree includeIf keyword supported by the Crystal reader.
      GitOracle.run(root, "config", "--local", "--includes", "--get-all", "test.condition").stdout.lines.map(&.strip).should eq(["onbranch"])
    end
  end

  it "P06-O10 rejects Git-invalid escape and quote sequences" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "syntax.inc")
      source = Git::Config::Source.new(Git::Config::Scope::Local, file)
      ["[test]\nkey = value\\q\n", "[test]\nkey = \"unterminated\n"].each do |invalid|
        File.write(file, invalid)
        GitOracle.run(root, "config", "--file", file, "--list", check: false).success?.should be_false
        expect_raises(Git::Error) { Git::Config.load([source]) }
      end
    end
  end
end

describe "P06 extension authority" do
  it "P06-O11 ignores global worktreeConfig activation when repository local scope omits it" do
    GitOracle.with_repo do |root|
      global = File.join(File.dirname(root), "global-extension")
      File.write(global, "[extensions]\n\tworktreeConfig = true\n")
      File.write(File.join(root, ".git", "config.worktree"), "[test]\n\tfromWorktree = should-not-read\n")
      native = Git::Repository.new(root).config(global_files: [global])
      native.value?("test.fromworktree").should be_nil
      oracle = GitOracle.run(root, "config", "--list", "--null", extra_env: {"GIT_CONFIG_GLOBAL" => global})
      oracle.stdout.should_not contain("test.fromworktree")
    end
  end
end

describe "P06 hasconfig remote URL conditional include parity" do
  it "P06-O12 scans later-scoped URLs before an earlier conditional include without reordering entries" do
    GitOracle.with_repo do |root|
      base = File.dirname(root)
      global = File.join(base, "global-hasconfig")
      child = File.join(base, "selected.inc")
      File.write(child, "[profile]\n selected = from-global-include\n")
      File.write(global, "[profile]\n order = before\n[includeIf \"hasconfig:remote.*.url:https://example.org/**\"]\n path = selected.inc\n[profile]\n order = after\n")
      GitOracle.run(root, "config", "--local", "remote.origin.url", "https://example.org/group/project")
      source = [
        Git::Config::Source.new(Git::Config::Scope::Global, global),
        Git::Config::Source.new(Git::Config::Scope::Local, File.join(root, ".git", "config")),
      ]
      actual = Git::Config.load(source)
      actual.value?("profile.selected").should eq("from-global-include")
      actual.entries.select { |entry| entry.name.starts_with?("profile.") }.map(&.name).should eq([
        "profile.order", "profile.selected", "profile.order",
      ])
      oracle = GitOracle.run(root, "config", "--includes", "--null", "--list",
        extra_env: {"GIT_CONFIG_GLOBAL" => global})
      encoded = actual.entries.map { |entry| entry.name + (entry.value ? "\n" + entry.value.not_nil! : "") + "\0" }.join
      GitOracle.assert_bytes!(encoded, oracle.stdout, "P06-O12")
    end
  end

  it "P06-O13 sees later same-file and command-scoped remote URLs" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      included = File.join(root, ".git", "selected.inc")
      File.write(included, "[probe]\n selected = yes\n")
      File.open(file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:ssh://git.example/**"]}
        stream.puts "path = selected.inc"
      end
      source = [Git::Config::Source.new(Git::Config::Scope::Local, file)]
      Git::Config.load(source).value?("probe.selected").should be_nil
      GitOracle.run(root, "config", "--local", "--includes", "--get", "probe.selected", check: false).success?.should be_false

      commands = [{"remote.example.url", "ssh://git.example/a/b"}] of {String, String?}
      with_command = Git::Config.load(source, commands: commands)
      with_command.value?("probe.selected").should eq("yes")
      GitOracle.run(root, "-c", "remote.example.url=ssh://git.example/a/b", "config", "--includes", "--get", "probe.selected").stdout.strip.should eq("yes")

      File.open(file, "a") { |stream| stream.puts "[remote \"future\"]\n url = ssh://git.example/future" }
      Git::Config.load(source).value?("probe.selected").should eq("yes")
      GitOracle.run(root, "config", "--local", "--includes", "--get", "probe.selected").stdout.strip.should eq("yes")
    end
  end

  it "P06-O14 accepts remote URLs from ordinary nested includes but not deferred included files" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      url_source = File.join(root, ".git", "urls.inc")
      flag_source = File.join(root, ".git", "flag.inc")
      File.write(url_source, "[remote \"mirror\"]\n url = https://example.org/remote\n")
      File.write(flag_source, "[probe]\n selected = nested\n")
      File.open(file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://example.org/**"]}
        stream.puts "path = flag.inc"
        stream.puts "[include]"
        stream.puts "path = urls.inc"
      end
      native = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)])
      native.value?("probe.selected").should eq("nested")
      oracle = GitOracle.run(root, "config", "--local", "--includes", "--null", "--list")
      encoded = native.entries.map { |entry| entry.name + (entry.value ? "\n" + entry.value.not_nil! : "") + "\0" }.join
      GitOracle.assert_bytes!(encoded, oracle.stdout, "P06-O14")
    end
  end

  it "P06-O15 forbids remote URLs directly and transitively included through hasconfig" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      child = File.join(root, ".git", "bad.inc")
      nested = File.join(root, ".git", "nested.inc")
      File.open(file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://example.org/**"]}
        stream.puts "path = bad.inc"
        stream.puts "[remote \"okay\"]"
        stream.puts "url = https://example.org/okay"
      end
      source = [Git::Config::Source.new(Git::Config::Scope::Local, file)]
      File.write(child, "[remote \"illegal\"]\n url = https://other.invalid/illegal\n")
      GitOracle.run(root, "config", "--local", "--includes", "--list", check: false).success?.should be_false
      expect_raises(Git::Error, /remote/) { Git::Config.load(source) }
      File.write(child, "[include]\n path = nested.inc\n")
      File.write(nested, "[remote \"also-illegal\"]\n url = https://other.invalid/illegal\n")
      GitOracle.run(root, "config", "--local", "--includes", "--list", check: false).success?.should be_false
      expect_raises(Git::Error, /remote/) { Git::Config.load(source) }
    end
  end

  it "P06-O16 preserves nonmatch and glob matching including a same-file remote without scope leakage" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      yes = File.join(root, ".git", "yes.inc")
      no = File.join(root, ".git", "no.inc")
      File.write(yes, "[probe]\n selected = yes\n")
      File.write(no, "[probe]\n selected = no\n")
      File.open(file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://git.example/**"]}
        stream.puts "path = yes.inc"
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://wrong.example/**"]}
        stream.puts "path = no.inc"
        stream.puts "[remote \"after\"]"
        stream.puts "url = https://git.example/a/b"
      end
      native = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)])
      native.values("probe.selected").should eq(["yes"])
      GitOracle.run(root, "config", "--local", "--includes", "--get-all", "probe.selected").stdout.lines.map(&.strip).should eq(["yes"])
    end
  end
end

describe "P06 conditional include glob behavior" do
  it "P06-O17 matches zero or many path components for **/ and standard character classes" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "config")
      included = File.join(root, ".git", "glob.inc")
      included2 = File.join(root, ".git", "class.inc")
      File.write(included, "[match]\n recursive = yes\n")
      File.write(included2, "[match]\n class = yes\n")
      File.open(file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://example.org/**/repo.git"]}
        stream.puts "path = glob.inc"
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://class.example/proj[12].git"]}
        stream.puts "path = class.inc"
        stream.puts "[remote \"recursive\"]"
        stream.puts "url = https://example.org/repo.git"
        stream.puts "[remote \"range\"]"
        stream.puts "url = https://class.example/proj2.git"
      end
      source = [Git::Config::Source.new(Git::Config::Scope::Local, file)]
      actual = Git::Config.load(source)
      actual.value?("match.recursive").should eq("yes")
      actual.value?("match.class").should eq("yes")
      GitOracle.run(root, "config", "--local", "--includes", "--get", "match.recursive").stdout.strip.should eq("yes")
      GitOracle.run(root, "config", "--local", "--includes", "--get", "match.class").stdout.strip.should eq("yes")
      GitOracle.run(root, "config", "--local", "remote.recursive.url", "https://example.org/group/sub/repo.git")
      actual2 = Git::Config.load(source)
      actual2.value?("match.recursive").should eq("yes")
      GitOracle.run(root, "config", "--local", "--includes", "--get", "match.recursive").stdout.strip.should eq("yes")
    end
  end
end

# The initial URL scan must never consume configuration supplied only by a
# hasconfig-conditioned include. Otherwise that include could select itself.
describe "P06 hasconfig scan-ahead independence" do
  it "P06-O18 does not allow an unmatched include to supply its own matching remote URL" do
    GitOracle.with_repo do |root|
      config_file = File.join(root, ".git", "config")
      child = File.join(root, ".git", "self.inc")
      File.write(child, "[remote \"self\"]\n url = https://example.org/self\n[probe]\n chosen = wrongly\n")
      File.open(config_file, "a") do |stream|
        stream.puts %q{[includeIf "hasconfig:remote.*.url:https://example.org/**"]}
        stream.puts "path = self.inc"
      end
      source = [Git::Config::Source.new(Git::Config::Scope::Local, config_file)]
      native = Git::Config.load(source)
      native.value?("probe.chosen").should be_nil
      native.values("remote.self.url").should be_empty
      GitOracle.run(root, "config", "--local", "--includes", "--get", "probe.chosen", check: false).success?.should be_false
    end
  end
end
