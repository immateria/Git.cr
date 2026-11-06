require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def eol_settings(repository : Git::Repository, auto : String = "false",
                         ending : String = "lf", safe : String = "false") : Git::Config
  values = [] of {String, String?}
  values << {"core.autocrlf", auto}
  values << {"core.eol", ending}
  values << {"core.safecrlf", safe}
  repository.config(command_values: values)
end

private def eol_attributes(root : String, contents : String) : Nil
  File.write(File.join(root, ".gitattributes"), contents)
end

private def eol_info_attributes(root : String, contents : String) : Nil
  directory = File.join(root, ".git", "info")
  Dir.mkdir_p(directory)
  File.write(File.join(directory, "attributes"), contents)
end

describe Git::Conversion do
  it "matches Git's native clean and checkout conversion over representative byte profiles" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      cases = [
        {"", "TRUE", "lf", "a\r\nb\r\n"},
        {"* text\n", "false", "CRLF", "a\nb\n"},
        {"* text\n", "INPUT", "CRLF", "a\r\nb\r\n"},
        {"* -text eol=crlf\n", "true", "lf", "a\r\nb\n"},
        {"* text eol=crlf\n", "false", "lf", "a\r\nb\n\0\n"},
        {"* text=auto eol=crlf\n", "false", "lf", "a\r\nb\n"},
        {"* text=auto eol=lf\n", "false", "crlf", "a\r\nb\n"},
        {"* eol=crlf\n", "input", "lf", "a\nb\n"},
        {"* text=true\n", "true", "lf", "a\r\nb\r\n"},
        {"* text=false\n", "false", "crlf", "a\r\nb\n"},
        {"* crlf=input\n", "true", "crlf", "a\r\nb\r\n"},
        {"* text=auto\n", "false", "crlf", "a\r\n\x1a"},
        {"* text=auto\n", "true", "lf", "a\rb\r\n"},
        {"* text=auto\n", "true", "lf", String.new(Bytes[0xff, 13, 10])},
      ]
      cases.each_with_index do |profile, index|
        attributes, auto, ending, data = profile
        eol_attributes(root, attributes)
        conversion = Git::Conversion.new(repository, config: eol_settings(repository, auto, ending))
        options = ["-c", "core.autocrlf=#{auto}", "-c", "core.eol=#{ending}", "-c", "core.safecrlf=false"]
        expected_oid = GitOracle.run_args(root, options + ["hash-object", "--path=sample.txt", "--stdin"], input: data).stdout.strip
        Git::ObjectId.digest("blob", conversion.clean("sample.txt", data)).should eq(expected_oid)
        raw_oid = repository.write_blob(data)
        expected_bytes = GitOracle.run_args(root, options + ["cat-file", "--filters", "--path=sample.txt", raw_oid]).stdout
        GitOracle.assert_bytes!(conversion.checkout("sample.txt", data), expected_bytes, "EOL-CORE-#{index}")
      end
    end
  end

  it "normalizes explicit text without changing NUL, lone CR or invalid UTF-8 bytes" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "* text eol=lf\n")
      input = String.new(Bytes[0xff, 13, 10, 0, 13, 120, 10])
      expected = String.new(Bytes[0xff, 10, 0, 13, 120, 10])
      Git::Conversion.new(repository).clean("file", input).to_slice.should eq(expected.to_slice)
    end
  end

  it "uses Git's full-payload auto binary heuristic and trailing DOS EOF exception" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "* text=auto\n")
      conversion = Git::Conversion.new(repository)
      ["a\0\r\n", "a\rb\r\n", "\x01\r\n", "a" * 127 + "\x01\r\n"].each do |binary|
        conversion.clean("file", binary).should eq(binary)
      end
      conversion.clean("file", "a" * 128 + "\x01\r\n").should eq("a" * 128 + "\x01\n")
      conversion.clean("file", "a\r\n\x1a").should eq("a\n\x1a")
    end
  end

  it "expands only bare LF under explicit text even in mixed binary content" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "* text eol=crlf\n")
      Git::Conversion.new(repository).checkout("file", "a\r\nb\nc\rd\n\0\n").should eq("a\r\nb\r\nc\rd\r\n\0\r\n")
    end
  end

  it "preserves mixed, binary and lone-CR blobs during automatic checkout" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "* text=auto eol=crlf\n")
      conversion = Git::Conversion.new(repository)
      ["a\r\nb\n", "a\rb\n", "a\0\n"].each { |bytes| conversion.checkout("file", bytes).should eq(bytes) }
      conversion.checkout("file", "a\nb\n").should eq("a\r\nb\r\n")
    end
  end

  it "loads repository-local autocrlf when the caller supplies no config" do
    GitOracle.with_repo do |root|
      File.open(File.join(root, ".git", "config"), "a") { |file| file << "\n[core]\n autocrlf = true\n" }
      Git::Conversion.new(Git::Repository.new(root)).clean("file", "a\r\n").should eq("a\n")
    end
  end

  it "preserves a textual CRLF index blob in auto mode unless renormalizing" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      oid = repository.stage_blob("file", "a\r\n")
      conversion = Git::Conversion.new(repository, config: eol_settings(repository, "true"))
      conversion.clean("file", "b\r\n", index_oid: oid).should eq("b\r\n")
      conversion.clean("file", "b\r\n", index_oid: oid, renormalize: true).should eq("b\n")
      eol_attributes(root, "* text\n")
      Git::Conversion.new(repository).clean("file", "b\r\n", index_oid: oid).should eq("b\n")
    end
  end

  it "does not let binary indexed CRLF bytes disable automatic normalization" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      oid = repository.stage_blob("file", "a\0\r\n")
      conversion = Git::Conversion.new(repository, config: eol_settings(repository, "true"))
      conversion.clean("file", "b\r\n", index_oid: oid).should eq("b\n")
    end
  end

  it "distinguishes attribute Set, Unset, String and explicit Unspecified states" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "*.txt text eol=crlf\nreset.txt !text\nunset.txt -text\nstring.txt text=false\n")
      attributes = Git::Attributes.new(repository)
      attributes.resolve("plain.txt", "text").kind.should eq(Git::Attributes::Kind::Set)
      attributes.resolve("reset.txt", "text").kind.should eq(Git::Attributes::Kind::Unspecified)
      attributes.resolve("reset.txt", "eol").text.should eq("crlf")
      attributes.resolve("unset.txt", "text").kind.should eq(Git::Attributes::Kind::Unset)
      attributes.resolve("string.txt", "text").kind.should eq(Git::Attributes::Kind::String)
      attributes.resolve("string.txt", "text").text.should eq("false")
      conversion = Git::Conversion.new(repository)
      conversion.checkout("reset.txt", "a\n").should eq("a\r\n")
      conversion.checkout("unset.txt", "a\n").should eq("a\n")
    end
  end

  it "applies hierarchy and info overrides independently for each attribute" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      Dir.mkdir_p(File.join(root, "sub"))
      eol_attributes(root, "*.txt text eol=crlf\n")
      File.write(File.join(root, "sub", ".gitattributes"), "*.txt eol=lf\n")
      eol_info_attributes(root, "sub/info.txt -text\n")
      attributes = Git::Attributes.new(repository)
      attributes.resolve("root.txt", "eol").text.should eq("crlf")
      attributes.resolve("sub/plain.txt", "text").kind.should eq(Git::Attributes::Kind::Set)
      attributes.resolve("sub/plain.txt", "eol").text.should eq("lf")
      attributes.resolve("sub/info.txt", "text").kind.should eq(Git::Attributes::Kind::Unset)
    end
  end

  it "expands macros only when the highest-priority macro state is Set" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "[attr]native text eol=crlf\n*.txt native\nreset.txt -native\n*.bin binary\nreset.bin -binary\n")
      attributes = Git::Attributes.new(repository)
      attributes.resolve("plain.txt", "text").kind.should eq(Git::Attributes::Kind::Set)
      attributes.resolve("plain.txt", "eol").text.should eq("crlf")
      attributes.resolve("reset.txt", "text").kind.should eq(Git::Attributes::Kind::Unspecified)
      attributes.resolve("plain.bin", "text").kind.should eq(Git::Attributes::Kind::Unset)
      attributes.resolve("reset.bin", "text").kind.should eq(Git::Attributes::Kind::Unspecified)
      expected = GitOracle.run(root, "check-attr", "text", "--", "reset.txt", "reset.bin").stdout
      expected.should contain("reset.txt: text: unspecified")
      expected.should contain("reset.bin: text: unspecified")
    end
  end

  it "allows empty macro definitions to override earlier and built-in macros" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "[attr]native text eol=crlf\n[attr]native\n[attr]binary\n*.txt native\n*.bin binary\n")
      expected = GitOracle.run(root, "check-attr", "text", "eol", "diff", "--", "file.txt", "file.bin").stdout
      expected.lines.each { |line| line.should end_with(": unspecified") }
      attributes = Git::Attributes.new(repository)
      ["file.txt", "file.bin"].each do |path|
        ["text", "eol", "diff"].each do |attribute|
          attributes.resolve(path, attribute).kind.should eq(Git::Attributes::Kind::Unspecified)
        end
      end
    end
  end

  it "strips a leading BOM from attribute files while preserving indexed blob bytes" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      content = "\uFEFF* text eol=crlf\n"
      eol_attributes(root, content)
      repository.stage_blob(".gitattributes", content)
      GitOracle.run(root, "check-attr", "text", "--", "file").stdout.should eq("file: text: set\n")
      Git::Conversion.new(repository).checkout("file", "a\n").should eq("a\r\n")
      File.delete(File.join(root, ".gitattributes"))
      GitOracle.run(root, "check-attr", "text", "--", "file").stdout.should eq("file: text: unspecified\n")
      Git::Conversion.new(repository).checkout("file", "a\n").should eq("a\n")
    end
  end

  it "ignores attribute lines at Git's length limit before trimming whitespace" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      [{2047, "set"}, {2048, "unspecified"}].each do |length, state|
        content = "* text" + " " * (length - 6) + "\n*.bin -text\n"
        eol_attributes(root, content)
        repository.stage_blob(".gitattributes", content)
        2.times do |source|
          File.delete(File.join(root, ".gitattributes")) if source == 1
          expected = GitOracle.run(root, "check-attr", "text", "--", "file", "file.bin").stdout
          expected.should eq("file: text: #{state}\nfile.bin: text: unset\n")
          attributes = Git::Attributes.new(repository)
          kind = state == "set" ? Git::Attributes::Kind::Set : Git::Attributes::Kind::Unspecified
          attributes.resolve("file", "text").kind.should eq(kind)
          attributes.resolve("file.bin", "text").kind.should eq(Git::Attributes::Kind::Unset)
        end
      end
    end
  end

  it "matches C-quoted spaces and octal-quoted raw filename bytes" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "\"space file\" text eol=crlf\n\"\\377file\" text eol=lf\n")
      attributes = Git::Attributes.new(repository)
      attributes.resolve("space file", "eol").text.should eq("crlf")
      raw = String.new(Bytes[0xff]) + "file"
      attributes.resolve(raw, "eol").text.should eq("lf")
    end
  end

  it "matches Git's pattern delimiters for unquoted and C-quoted attributes" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      ["*", "\"*\""].each do |pattern|
        [" ", "\t", "\r", "\v", "\f"].each do |separator|
          content = pattern + separator + "text\n"
          eol_attributes(root, content)
          repository.stage_blob(".gitattributes", content)
          state = {" ", "\t", "\r"}.includes?(separator) ? "set" : "unspecified"
          2.times do |source|
            File.delete(File.join(root, ".gitattributes")) if source == 1
            GitOracle.run(root, "check-attr", "text", "--", "file").stdout.should eq("file: text: #{state}\n")
            attributes = Git::Attributes.new(repository)
            kind = state == "set" ? Git::Attributes::Kind::Set : Git::Attributes::Kind::Unspecified
            attributes.resolve("file", "text").kind.should eq(kind)
          end
        end
      end
      eol_attributes(root, "* text\r\n")
      GitOracle.run(root, "check-attr", "text", "--", "file").stdout.should eq("file: text: set\n")
      Git::Attributes.new(repository).resolve("file", "text").kind.should eq(Git::Attributes::Kind::Set)
    end
  end

  it "accepts attributes immediately after a C-quoted pattern" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "\"*\"text\reol=crlf\n")
      GitOracle.run(root, "check-attr", "text", "eol", "--", "file").stdout.should eq("file: text: set\nfile: eol: crlf\n")
      Git::Conversion.new(repository).checkout("file", "a\n").should eq("a\r\n")
    end
  end

  it "does not treat other whitespace bytes as attribute delimiters" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      ["\v", "\f", "\u00a0"].each do |other|
        [other + "* text\n", "*\r" + other + "text\n", "* text" + other + "eol=crlf\n", "\"*\"" + other + "text\n"].each do |content|
          eol_attributes(root, content)
          GitOracle.run(root, "check-attr", "text", "--", "file").stdout.should eq("file: text: unspecified\n")
          Git::Attributes.new(repository).resolve("file", "text").kind.should eq(Git::Attributes::Kind::Unspecified)
        end
      end
    end
  end

  it "uses working attributes first and indexed attributes when missing or symlinked" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      repository.stage_blob(".gitattributes", "* text eol=lf\n")
      eol_attributes(root, "* -text\n")
      Git::Conversion.new(repository).clean("file", "a\r\n").should eq("a\r\n")
      File.delete(File.join(root, ".gitattributes"))
      Git::Conversion.new(repository).clean("file", "a\r\n").should eq("a\n")
      outside = File.join(File.dirname(root), "outside-attrs")
      File.write(outside, "* -text\n")
      File.symlink(outside, File.join(root, ".gitattributes"))
      Git::Conversion.new(repository).clean("file", "a\r\n").should eq("a\n")
    end
  end

  it "does not read attributes through a symlinked working directory" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      repository.stage_blob("sub/.gitattributes", "* text eol=lf\n")
      outside = File.join(File.dirname(root), "outside")
      Dir.mkdir_p(outside)
      File.write(File.join(outside, ".gitattributes"), "* -text\n")
      File.symlink(outside, File.join(root, "sub"))
      Git::Conversion.new(repository).clean("sub/file", "a\r\n").should eq("a\n")
    end
  end

  it "uses target-tree or complete blob-map attributes without stale worktree fallback" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      attr_oid = repository.stage_blob(".gitattributes", "* text eol=crlf\n")
      repository.stage_blob("file", "a\n")
      tree = repository.write_index_tree
      eol_attributes(root, "* -text\n")
      Git::Conversion.new(repository, attribute_tree: tree).checkout("file", "a\n").should eq("a\r\n")
      mapped = {".gitattributes" => attr_oid.as(String?)} of String => String?
      Git::Conversion.new(repository, attribute_blobs: mapped).checkout("file", "a\n").should eq("a\r\n")
      deleted = {".gitattributes" => nil.as(String?)} of String => String?
      Git::Conversion.new(repository, attribute_blobs: deleted).checkout("file", "a\n").should eq("a\n")
    end
  end

  it "enforces safecrlf reversibility and records warn diagnostics without blocking" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      rejecting = Git::Conversion.new(repository, config: eol_settings(repository, "true", "lf", "true"))
      expect_raises(Git::Error, /LF would be replaced by CRLF/) { rejecting.clean("file", "a\n", safe: true) }
      rejecting.clean("file", "a\n").should eq("a\n")
      input = Git::Conversion.new(repository, config: eol_settings(repository, "INPUT", "crlf", "true"))
      expect_raises(Git::Error, /CRLF would be replaced by LF/) { input.clean("file", "a\r\n", safe: true) }
      warning = Git::Conversion.new(repository, config: eol_settings(repository, "true", "lf", "WARN"))
      warning.clean("file", "a\n", safe: true).should eq("a\n")
      warning.warnings.size.should eq(1)
    end
  end

  it "bounds input, expanded output and accumulated attribute bytes" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      config = eol_settings(repository, "true")
      conversion = Git::Conversion.new(repository, config: config, max_bytes: 4)
      expect_raises(Git::Error, /conversion byte budget/) { conversion.clean("file", "12345") }
      expect_raises(Git::Error, /conversion byte budget/) { conversion.checkout("file", "a\nb\n") }
      eol_attributes(root, "* text\n")
      eol_info_attributes(root, "* text\n")
      expect_raises(Git::Error, /attribute byte budget/) { Git::Conversion.new(repository, config: config, max_bytes: 10) }
    end
  end

  it "keeps index and converted-content byte budgets independent" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      repository.stage_blob(".gitattributes", "* text=auto\n")
      repository.stage_blob("file", "a\r\n")
      5.times { |index| repository.stage_blob("filler-#{index}", "x") }
      config = eol_settings(repository, "true")
      Git::Conversion.new(repository, config: config, max_bytes: 32).clean("file", "b\r\n").should eq("b\r\n")
      conversion = Git::Conversion.new(repository, config: config, max_bytes: 32, max_index_bytes: 8192)
      conversion.clean("file", "b\r\n").should eq("b\r\n")
      mapped = Git::Conversion.new(repository, config: config, max_bytes: 32, max_index_bytes: 8192,
        attribute_blobs: {} of String => String?)
      mapped.clean("file", "b\r\n").should eq("b\r\n")
      expect_raises(Git::Error, /index/) do
        Git::Conversion.new(repository, config: config, max_bytes: 8192, max_index_bytes: 128)
      end
      limited = Git::Conversion.new(repository, config: config, max_bytes: 8192, max_index_bytes: 128,
        attribute_blobs: {} of String => String?)
      expect_raises(Git::Error, /index/) { limited.clean("file", "b\r\n") }
    end
  end

  it "bounds aggregate rules and polls cancellation during byte scans" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      eol_attributes(root, "* text\n" * 4097)
      expect_raises(Git::Error, /attribute rule budget/) { Git::Conversion.new(repository) }
      File.delete(File.join(root, ".gitattributes"))
      active = false
      polls = 0
      check = -> do
        if active
          polls += 1
          raise Git::Error.new("cancelled conversion") if polls >= 4
        end
      end
      conversion = Git::Conversion.new(repository, config: eol_settings(repository, "true"),
        attribute_blobs: {} of String => String?, check: check)
      active = true
      expect_raises(Git::Error, "cancelled conversion") { conversion.checkout("file", "a\n" * 3000) }
      polls.should eq(4)
    end
  end

  it "polls cancellation while scanning CRLF pairs that cross polling boundaries" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      active = false
      polls = 0
      check = -> do
        if active
          polls += 1
          raise Git::Error.new("cancelled CRLF scan") if polls >= 4
        end
      end
      conversion = Git::Conversion.new(repository, config: eol_settings(repository, "true"),
        attribute_blobs: {} of String => String?, check: check)
      active = true
      expect_raises(Git::Error, "cancelled CRLF scan") do
        conversion.checkout("file", "a" + "\r\n" * 6000)
      end
      polls.should eq(4)
    end
  end
end
