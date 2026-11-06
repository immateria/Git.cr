require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

module EolStashFixture
  LF   = "*.txt text eol=lf\n"
  CRLF = "*.txt text eol=crlf\n"

  def self.actor : Git::Signature
    Git::Signature.new("EOL Stash", "eol-stash@example.invalid", 1_700_000_000_i64, 0)
  end

  def self.base(root : String, attributes : String = CRLF, text : String = "base\n") : Git::Repository
    File.write(File.join(root, ".gitattributes"), attributes)
    File.write(File.join(root, "file.txt"), text)
    GitOracle.run(root, "add", ".")
    GitOracle.run(root, "commit", "-qm", "base")
    Git::Repository.new(root)
  end

  def self.blob(root : String, expression : String) : String
    GitOracle.run(root, "show", expression).stdout
  end
end

describe "native stash text/EOL capture and cleanup" do
  ["sha1", "sha256"].each do |format|
    it "stores canonical #{format} tracked, index and untracked trees and smudges cleanup" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "staged\r\n")
        GitOracle.run(root, "add", "file.txt")
        File.write(File.join(root, "file.txt"), "working\r\n")
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\n")
        EolStashFixture.blob(root, "#{entry.index_oid}:file.txt").should eq("staged\n")
        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("untracked\n")
        {"#{entry.oid}:file.txt"          => "working\n",
         "#{entry.index_oid}:file.txt"    => "staged\n",
         "#{entry.untracked_oid}:new.txt" => "untracked\n"}.each do |expression, content|
          GitOracle.run(root, "rev-parse", expression).stdout.strip.should eq(
            Git::ObjectId.digest("blob", content, repo.object_format))
        end
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
        File.exists?(File.join(root, "new.txt")).should be_false
      end
    end

    it "treats clean #{format} CRLF working bytes as a canonical no-op" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "base\r\n")
        repo.stash.push(actor: EolStashFixture.actor).should be_nil
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
      end
    end

    it "preserves canonical #{format} index state and CRLF bytes for keep_index" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "staged\r\n")
        GitOracle.run(root, "add", "file.txt")
        index_before = File.read(File.join(root, ".git", "index"))
        File.write(File.join(root, "file.txt"), "working\r\n")
        repo.stash.push(actor: EolStashFixture.actor, keep_index: true).should_not be_nil
        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
        File.read(File.join(root, ".git", "index")).should eq(index_before)
      end
    end

    it "merges canonical #{format} staged-only cleanup while preserving unstaged edits" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, text: "base\nkeep\n")
        File.write(File.join(root, "file.txt"), "staged\r\nkeep\r\n")
        GitOracle.run(root, "add", "file.txt")
        File.write(File.join(root, "file.txt"), "staged\r\nkeep\r\nunstaged\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, staged_only: true).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("staged\nkeep\n")
        File.read(File.join(root, "file.txt")).should eq("base\r\nkeep\r\nunstaged\r\n")
      end
    end

    it "uses original worktree attributes for selected #{format} default cleanup" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
        File.write(File.join(root, "file.txt"), "working\r\n")
        repo.stash.push(actor: EolStashFixture.actor, paths: [".gitattributes", "file.txt"]).should_not be_nil
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
        File.read(File.join(root, "file.txt")).should eq("base\n")
      end
    end

    it "uses selected index attributes and unselected working attributes for #{format} keep_index cleanup" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, EolStashFixture::LF)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "file.txt"), "staged\r\n")
        GitOracle.run(root, "add", ".")
        File.write(File.join(root, ".gitattributes"), "*.txt -text\n")
        File.write(File.join(root, "file.txt"), "working\r\n")
        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
          paths: [".gitattributes", "file.txt"]).should_not be_nil
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
        File.write(File.join(root, "file.txt"), "again\r\n")
        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
          paths: ["file.txt"]).should_not be_nil
        File.read(File.join(root, "file.txt")).should eq("staged\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
      end
    end

    it "uses current worktree attributes for #{format} capture and HEAD attributes for full cleanup" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, EolStashFixture::LF)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        GitOracle.run(root, "add", ".gitattributes")
        File.write(File.join(root, ".gitattributes"), "*.txt -text\n")
        File.write(File.join(root, "file.txt"), "working\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\r\n")
        File.read(File.join(root, "file.txt")).should eq("base\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
      end
    end

    it "honors default and explicit #{format} config without rejecting unchanged safecrlf predecessors" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "")
        GitOracle.run(root, "config", "core.autocrlf", "true")
        GitOracle.run(root, "config", "core.safecrlf", "true")
        File.write(File.join(root, "new.txt"), "new\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("new\n")
        File.write(File.join(root, "file.txt"), "working\r\n")
        explicit = repo.config(command_values: [{"core.autocrlf", "false"}])
        entry = repo.stash.push(actor: EolStashFixture.actor, config: explicit).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\r\n")
      end
    end

    it "refuses unsafe changed and new #{format} captures before publishing refs" do
      [false, true].each do |untracked|
        GitOracle.with_repo(format: format) do |root|
          repo = EolStashFixture.base(root, "")
          GitOracle.run(root, "config", "core.autocrlf", "true")
          GitOracle.run(root, "config", "core.safecrlf", "true")
          path = File.join(root, untracked ? "new.txt" : "file.txt")
          File.write(path, "working\n")
          expect_raises(Git::Error, /LF would be replaced by CRLF/) do
            repo.stash.push(actor: EolStashFixture.actor, include_untracked: untracked)
          end
          repo.refs.resolve?("refs/stash").should be_nil
          File.read(path).should eq("working\n")
          File.exists?(File.join(root, ".git", "index.lock")).should be_false
        end
      end
    end

    it "warns once per #{format} capture and treats warning callbacks as arbitrary code" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "")
        GitOracle.run(root, "config", "core.autocrlf", "true")
        GitOracle.run(root, "config", "core.safecrlf", "warn")
        path = File.join(root, "file.txt")
        File.write(path, "working\n")
        warnings = [] of String
        callback = ->(message : String) { warnings << message; nil }
        repo.stash.push(actor: EolStashFixture.actor, warning: callback).should_not be_nil
        warnings.size.should eq(1)
        File.write(path, "next\n")
        changing = ->(_message : String) { File.write(path, "next\r\n"); nil }
        previous = repo.refs.resolve?("refs/stash")
        expect_raises(Git::Error, /worktree changed during save/) do
          repo.stash.push(actor: EolStashFixture.actor, warning: changing)
        end
        repo.refs.resolve?("refs/stash").should eq(previous)
        File.read(path).should eq("next\r\n")
      end
    end

    it "rejects expanded #{format} cleanup before reference or worktree publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, text: "x\n" * 100)
        File.write(File.join(root, "file.txt"), "working\r\n")
        before = File.read(File.join(root, ".git", "index"))
        expect_raises(Git::Error, /conversion byte budget/) do
          repo.stash.push(actor: EolStashFixture.actor, max_object_bytes: 256,
            max_total_bytes: 2048_i64)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "file.txt")).should eq("working\r\n")
        File.read(File.join(root, ".git", "index")).should eq(before)
      end
    end

    it "keeps raw #{format} binary and symlink content outside text conversion" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "* text=auto eol=crlf\n")
        binary = "binary\0\r\n"
        File.write(File.join(root, "file.txt"), binary)
        File.symlink("target\r\n", File.join(root, "link"))
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq(binary)
        EolStashFixture.blob(root, "#{entry.untracked_oid}:link").should eq("target\r\n")
      end
    end

    it "preserves raw #{format} working bytes when a cleanup callback changes only EOLs" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        path = File.join(root, "file.txt")
        File.write(path, "working\r\n")
        changed = false
        check = -> do
          if !changed && repo.refs.resolve?("refs/stash")
            changed = true
            File.write(path, "working\n")
          end
          nil
        end
        error = expect_raises(Git::Stash::PartialSave) do
          repo.stash.push(actor: EolStashFixture.actor, check: check)
        end
        error.changed_paths.should be_empty
        repo.refs.resolve?("refs/stash").should eq(error.stash_oid)
        File.read(path).should eq("working\n")
      end
    end

    it "fails #{format} warning callback errors before stash publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "")
        GitOracle.run(root, "config", "core.autocrlf", "true")
        GitOracle.run(root, "config", "core.safecrlf", "warn")
        File.write(File.join(root, "new.txt"), "working\n")
        warning = ->(_message : String) { raise "warning cancelled"; nil }
        expect_raises(Exception, "warning cancelled") do
          repo.stash.push(actor: EolStashFixture.actor, include_untracked: true, warning: warning)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "new.txt")).should eq("working\n")
      end
    end

    it "enforces the aggregate expanded #{format} cleanup budget before publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, text: "x\n" * 64)
        File.write(File.join(root, "file.txt"), "changed\n" * 15)
        before = File.read(File.join(root, ".git", "index"))
        expect_raises(Git::Error, /total byte budget/) do
          repo.stash.push(actor: EolStashFixture.actor, max_object_bytes: 256,
            max_total_bytes: 256_i64)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, "file.txt")).should eq("changed\n" * 15)
        File.read(File.join(root, ".git", "index")).should eq(before)
      end
    end

    it "keeps exact #{format} selected path scope with nested attributes" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, EolStashFixture::LF)
        Dir.mkdir(File.join(root, "nested"))
        File.write(File.join(root, "nested", ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "nested", "literal[1].txt"), "base\n")
        File.write(File.join(root, "nested", "literal1.txt"), "other\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "nested")
        File.write(File.join(root, "nested", "literal[1].txt"), "changed\r\n")
        File.write(File.join(root, "nested", "literal1.txt"), "untouched\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, paths: ["nested/literal[1].txt"]).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:nested/literal[1].txt").should eq("changed\n")
        EolStashFixture.blob(root, "#{entry.oid}:nested/literal1.txt").should eq("other\n")
        File.read(File.join(root, "nested", "literal[1].txt")).should eq("base\r\n")
        File.read(File.join(root, "nested", "literal1.txt")).should eq("untouched\r\n")
      end
    end

    it "retains indexed #{format} attributes when unselected worktree attributes are missing" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "staged\r\n")
        GitOracle.run(root, "add", "file.txt")
        File.delete(File.join(root, ".gitattributes"))
        File.write(File.join(root, "file.txt"), "working\r\n")
        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
          paths: ["file.txt"]).should_not be_nil
        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
        File.exists?(File.join(root, ".gitattributes")).should be_false
      end
    end

    it "refuses #{format} warning callbacks that change the index before publishing a stale plan" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "")
        GitOracle.run(root, "config", "core.autocrlf", "true")
        GitOracle.run(root, "config", "core.safecrlf", "warn")
        File.write(File.join(root, "file.txt"), "working\n")
        staged = "new staged content\n"
        warning = ->(_message : String) { repo.stage_blob("file.txt", staged); nil }
        expect_raises(Git::Error, /index changed/) do
          repo.stash.push(actor: EolStashFixture.actor, warning: warning)
        end
        EolStashFixture.blob(root, ":file.txt").should eq(staged)
        File.read(File.join(root, "file.txt")).should eq("working\n")
        repo.refs.resolve?("refs/stash").should be_nil
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end

    it "does not parse selected #{format} symlink attribute targets as attribute data" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        attributes = File.join(root, ".gitattributes")
        File.delete(attributes)
        File.symlink(EolStashFixture::CRLF, attributes)
        File.write(File.join(root, "file.txt"), "staged\n")
        GitOracle.run(root, "add", ".")
        File.write(File.join(root, "file.txt"), "working\r\n")
        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
          paths: [".gitattributes", "file.txt"]).should_not be_nil
        File.read(File.join(root, "file.txt")).should eq("staged\n")
        File.readlink(attributes).should eq(EolStashFixture::CRLF)
      end
    end

    it "admits only canonical-clean #{format} content excluded by a staged deletion and keeps raw guards" do
      [false, true].each do |modified|
        GitOracle.with_repo(format: format) do |root|
          repo = EolStashFixture.base(root)
          GitOracle.run(root, "rm", "--cached", "-q", "file.txt")
          raw = modified ? "modified\r\n" : "base\r\n"
          File.write(File.join(root, "file.txt"), raw)
          if modified
            expect_raises(Git::Error, /excluded by staged deletion/) do
              repo.stash.push(actor: EolStashFixture.actor)
            end
            repo.refs.resolve?("refs/stash").should be_nil
          else
            repo.stash.push(actor: EolStashFixture.actor).should_not be_nil
            EolStashFixture.blob(root, ":file.txt").should eq("base\n")
          end
          File.read(File.join(root, "file.txt")).should eq(raw)
        end
      end
    end
  end
end
