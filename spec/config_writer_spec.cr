require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P06 explicit transactional Git config writes" do
  it "P06-O54 sets new and existing values and matches Git's effective list" do
    GitOracle.with_repo do |root|
      native = File.join(root, ".git", "native-write.conf")
      oracle = File.join(root, ".git", "oracle-write.conf")
      File.write(native, "# keep comment\n[core]\n\tfilemode = true\n")
      File.copy(native, oracle)
      Git::Config::FileEditor.set(native, "core.filemode", "false")
      GitOracle.run(root, "config", "--file", oracle, "core.filemode", "false")
      Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, native)]).value?("core.filemode").should eq("false")
      GitOracle.assert_bytes!(GitOracle.run(root, "config", "--file", native, "--null", "--list").stdout,
        GitOracle.run(root, "config", "--file", oracle, "--null", "--list").stdout, "P06-O54")
      File.read(native).should contain("# keep comment")
      Git::Config::FileEditor.set(native, "feature.enabled", "yes")
      GitOracle.run(root, "config", "--file", oracle, "feature.enabled", "yes")
      GitOracle.assert_bytes!(GitOracle.run(root, "config", "--file", native, "--null", "--list").stdout,
        GitOracle.run(root, "config", "--file", oracle, "--null", "--list").stdout, "P06-O54-new")
      File.exists?(native + ".lock").should be_false
    end
  end

  it "P06-O55 adds, replaces and removes multivalues without changing unrelated entries" do
    GitOracle.with_repo do |root|
      original = "# retained\n[demo]\n\tflag = first\n\tother = preserved\n\tflag = second\n[branch \"Mixed.Case\"]\n\tmerge = main\n"
      native = File.join(root, ".git", "native.conf")
      oracle = File.join(root, ".git", "oracle.conf")
      File.write(native, original)
      File.write(oracle, original)
      Git::Config::FileEditor.add(native, "demo.flag", "third")
      GitOracle.run(root, "config", "--file", oracle, "--add", "demo.flag", "third")
      Git::Config::FileEditor.replace_all(native, "demo.flag", "final")
      GitOracle.run(root, "config", "--file", oracle, "--replace-all", "demo.flag", "final")
      Git::Config::FileEditor.unset(native, "demo.flag")
      GitOracle.run(root, "config", "--file", oracle, "--unset", "demo.flag")
      Git::Config::FileEditor.set(native, "branch.Mixed.Case.remote", "origin")
      GitOracle.run(root, "config", "--file", oracle, "branch.Mixed.Case.remote", "origin")
      GitOracle.assert_bytes!(GitOracle.run(root, "config", "--file", native, "--null", "--list").stdout,
        GitOracle.run(root, "config", "--file", oracle, "--null", "--list").stdout, "P06-O55")
      File.read(native).should contain("other = preserved")
      File.read(native).should contain("# retained")
    end
  end

  it "P06-O56 rejects ambiguous set or unset without mutating the file" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "ambiguous.conf")
      original = "[test]\n\tlist = one\n\tlist = two\n"
      File.write(file, original)
      GitOracle.run(root, "config", "--file", file, "test.list", "new", check: false).success?.should be_false
      expect_raises(Git::Error, /multiple/) { Git::Config::FileEditor.set(file, "test.list", "new") }
      expect_raises(Git::Error, /multiple/) { Git::Config::FileEditor.unset(file, "test.list") }
      File.read(file).should eq(original)
      File.exists?(file + ".lock").should be_false
      Git::Config::FileEditor.unset_all(file, "test.list")
      GitOracle.run(root, "config", "--file", file, "--get-all", "test.list", check: false).success?.should be_false
      File.read(file).should contain("[test]")
    end
  end

  it "P06-O57 treats existing Git lock as exclusive and leaves it intact" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "blocked.conf")
      original = "[test]\n\tvalue = original\n"
      File.write(file, original)
      File.write(file + ".lock", "external owner")
      GitOracle.run(root, "config", "--file", file, "test.value", "changed", check: false).success?.should be_false
      expect_raises(Git::Error, /lock/) { Git::Config::FileEditor.set(file, "test.value", "changed") }
      File.read(file).should eq(original)
      File.read(file + ".lock").should eq("external owner")
    end
  end

  it "P06-O58 encodes whitespace, newlines, comments and escapes compatibly" do
    GitOracle.with_repo do |root|
      native = File.join(root, ".git", "values-native.conf")
      oracle = File.join(root, ".git", "values-oracle.conf")
      ["plain", "two words", " leading and trailing ", "hash # and semi ;", "quoted \" and \\ slash", "line1\nline2", "tab\tinside", "back\bspace", ""].each_with_index do |value, idx|
        key = "test.val#{idx}"
        Git::Config::FileEditor.set(native, key, value)
        GitOracle.run(root, "config", "--file", oracle, key, value)
        Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, native)]).value?(key).should eq(value)
        GitOracle.assert_bytes!(GitOracle.run(root, "config", "--file", native, "--get", key).stdout,
          GitOracle.run(root, "config", "--file", oracle, "--get", key).stdout, "P06-O58-#{idx}")
      end
    end
  end

  it "P06-O59 preserves existing permissions and refuses symlink targets" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "private.conf")
      File.write(file, "[test]\n\tvalue = before\n")
      File.chmod(file, 0o600)
      Git::Config::FileEditor.set(file, "test.value", "after")
      File.info(file).permissions.value.should eq(0o600)
      symlink = File.join(root, ".git", "link.conf")
      File.symlink(file, symlink)
      expect_raises(Git::Error, /regular file/) { Git::Config::FileEditor.set(symlink, "test.value", "escape") }
      File.read(file).should contain("value = after")
      File.exists?(symlink + ".lock").should be_false
    end
  end

  it "P06-O60 rejects malformed input and byte overrun without leaking locks" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "malformed.conf")
      File.write(file, "[broken\n\tkey = value\n")
      expect_raises(Git::Error) { Git::Config::FileEditor.set(file, "test.flag", "true") }
      File.read(file).should eq("[broken\n\tkey = value\n")
      File.exists?(file + ".lock").should be_false
      File.write(file, "[test]\n\tvalue = " + "x" * 512)
      expect_raises(Git::Error, /budget/) { Git::Config::FileEditor.set(file, "test.value", "new", max_bytes: 256) }
      File.exists?(file + ".lock").should be_false
      expect_raises(Git::Error, /unsupported/) { Git::Config::FileEditor.set(file, "test.value", "contains\0zero") }
      File.exists?(file + ".lock").should be_false
    end
  end

  it "P06-O61 does not write through include files when changing explicit file" do
    GitOracle.with_repo do |root|
      parent = File.join(root, ".git", "parent.conf")
      child = File.join(root, ".git", "child.conf")
      File.write(child, "[feature]\n\tvalue = included\n")
      File.write(parent, "[include]\n\tpath = child.conf\n[feature]\n\tother = local\n")
      Git::Config::FileEditor.set(parent, "feature.value", "direct")
      File.read(child).should eq("[feature]\n\tvalue = included\n")
      result = Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, parent)])
      result.values("feature.value").should eq(["included", "direct"])
      GitOracle.run(root, "config", "--file", parent, "--get", "feature.value").stdout.strip.should eq("direct")
    end
  end
  it "P06-O62 refuses unparseable existing assignments and unsafe key headers" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "invalid-values.conf")
      ["[test]\n\tvalue = \"unterminated\n", "[test]\n\tvalue = invalid\\q\n", "[test]\n\tvalue stray\n"].each do |bad|
        File.write(file, bad)
        GitOracle.run(root, "config", "--file", file, "test.value", "new", check: false).success?.should be_false
        expect_raises(Git::Error) { Git::Config::FileEditor.set(file, "test.value", "new") }
        File.read(file).should eq(bad)
        File.exists?(file + ".lock").should be_false
      end
      File.write(file, "[test]\n\tvalue = original\n")
      expect_raises(Git::Error, /key/) { Git::Config::FileEditor.set(file, "remote.bad\n[evil].url", "injection") }
      File.read(file).should eq("[test]\n\tvalue = original\n")
    end
  end

  it "P06-O63 preserves multiline logical entries and unrelated CRLF bytes" do
    GitOracle.with_repo do |root|
      file = File.join(root, ".git", "continued.conf")
      original = "# keep\r\n[demo]\r\n\tvalue = before\\\n continued\r\n\tother = unchanged\r\n"
      File.write(file, original)
      Git::Config::FileEditor.set(file, "demo.value", "after")
      File.read(file).should contain("# keep\r\n[demo]\r\n")
      File.read(file).should contain("\tother = unchanged\r\n")
      Git::Config.load([Git::Config::Source.new(Git::Config::Scope::Local, file)]).value?("demo.value").should eq("after")
      File.read(file).should_not contain("continued")
    end
  end

  it "P06-O64 requires an explicit target file and updates subsequently loaded store config" do
    GitOracle.with_repo do |root|
      store = Git::Repository.new(root)
      file = File.join(root, ".git", "config")
      Git::Config::FileEditor.set(file, "core.filemode", "false")
      store.config.boolean?("core.filemode").should be_false
      GitOracle.run(root, "config", "--local", "--type=bool", "--get", "core.filemode").stdout.strip.should eq("false")
      expect_raises(Git::Error, /lock/) { Git::Config::FileEditor.add(File.join(root, "absent", "file"), "test.key", "x") }
      File.exists?(File.join(root, "absent", "file")).should be_false
    end
  end
end
