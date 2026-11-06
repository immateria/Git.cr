require "./eol_stash_spec"

describe "native stash text/EOL apply and pop" do
  ["sha1", "sha256"].each do |format|
    it "applies canonical #{format} mixed state with CRLF outputs and exact saved index restoration" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "staged\r\n")
        GitOracle.run(root, "add", "file.txt")
        staged = GitOracle.run(root, "rev-parse", ":file.txt").stdout.strip
        File.write(File.join(root, "file.txt"), "working\r\n")
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        GitOracle.run(root, "stash", "apply", "-q", "--index")
        expected_work = File.read(File.join(root, "file.txt"))
        expected_untracked = File.read(File.join(root, "new.txt"))
        expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        File.delete(File.join(root, "new.txt"))
        result = repo.stash.apply(actor: EolStashFixture.actor, restore_index: true)
        result.conflicts.should be_empty
        result.index_restored.should be_true
        File.read(File.join(root, "file.txt")).should eq(expected_work)
        File.read(File.join(root, "new.txt")).should eq(expected_untracked)
        GitOracle.run(root, "rev-parse", ":file.txt").stdout.strip.should eq(staged)
        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
      end
    end

    it "keeps third-parent #{format} attributes out of tracked replay and applies them to untracked restore" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "file.txt"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\n")
        repo.stash.pop(actor: EolStashFixture.actor).dropped.should be_true
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
        repo.refs.resolve?("refs/stash").should be_nil
      end
    end

    it "uses planned tracked #{format} attributes for both replay and supplemental restore" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, EolStashFixture::LF)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "file.txt"), "working\r\n")
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
        File.read(File.join(root, "file.txt")).should eq("working\r\n")
        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
      end
    end

    it "propagates explicit and default #{format} conversion config through apply and pop" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "")
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, "new.txt"), "untracked\n")
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        GitOracle.run(root, "config", "core.autocrlf", "true")
        explicit = repo.config(command_values: [{"core.autocrlf", "false"}])
        repo.stash.apply(actor: EolStashFixture.actor, config: explicit).conflicts.should be_empty
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, "new.txt")).should eq("untracked\n")
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        File.delete(File.join(root, "new.txt"))
        repo.stash.pop(actor: EolStashFixture.actor).dropped.should be_true
        File.read(File.join(root, "file.txt")).should eq("working\r\n")
        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
      end
    end

    it "retains canonical #{format} conflict stages and smudges conflict markers without dropping the stash" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "stashed\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
        File.write(File.join(root, "file.txt"), "current\r\n")
        GitOracle.run(root, "add", "file.txt")
        GitOracle.run(root, "commit", "-qm", "current")
        result = repo.stash.pop(actor: EolStashFixture.actor)
        result.dropped.should be_false
        result.applied.conflicts.should eq(["file.txt"])
        data = File.read(File.join(root, "file.txt"))
        data.should contain("<<<<<<< HEAD\r\n")
        data.gsub("\r\n", "").should_not contain('\n')
        EolStashFixture.blob(root, ":1:file.txt").should eq("base\n")
        EolStashFixture.blob(root, ":2:file.txt").should eq("current\n")
        EolStashFixture.blob(root, ":3:file.txt").should eq("stashed\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "rejects expanded supplemental #{format} files before tracked publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "working\r\n")
        File.write(File.join(root, "new.txt"), "u\r\n" * 200)
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        before = File.read(File.join(root, ".git", "index"))
        expect_raises(Git::Error, /conversion byte budget/) do
          repo.stash.apply(actor: EolStashFixture.actor, max_object_bytes: 512,
            max_total_bytes: 4096_i64)
        end
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
        File.exists?(File.join(root, "new.txt")).should be_false
        File.read(File.join(root, ".git", "index")).should eq(before)
        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
        File.exists?(File.join(root, ".git", "CRYSTAL_SEQUENCER_PATHS")).should be_false
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "reserves expanded #{format} supplemental bytes before materializing tracked writes" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.write(File.join(root, "file.txt"), "x\r\n" * 100)
        File.write(File.join(root, "new.txt"), "u\r\n" * 100)
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        before = File.read(File.join(root, ".git", "index"))
        expect_raises(Git::Error, /total byte budget/) do
          repo.stash.apply(actor: EolStashFixture.actor, max_object_bytes: 512,
            max_total_bytes: 512_i64)
        end
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
        File.exists?(File.join(root, "new.txt")).should be_false
        File.read(File.join(root, ".git", "index")).should eq(before)
      end
    end

    it "keeps current #{format} attributes and all supplemental destinations on a third-parent collision" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "file.txt"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
        error = expect_raises(Git::Stash::PartialApply) do
          repo.stash.pop(actor: EolStashFixture.actor)
        end
        error.stash_oid.should eq(entry.oid)
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
        File.exists?(File.join(root, "new.txt")).should be_false
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "uses deleted planned #{format} attributes without falling back to pre-apply worktree rules" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        File.delete(File.join(root, ".gitattributes"))
        File.write(File.join(root, "file.txt"), "working\r\n")
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
        File.exists?(File.join(root, ".gitattributes")).should be_false
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, "new.txt")).should eq("untracked\n")
      end
    end

    it "leaves unchanged #{format} canonical blobs untouched during attributes-only replay" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, EolStashFixture::LF)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        repo.stash.push(actor: EolStashFixture.actor).should_not be_nil
        result = repo.stash.apply(actor: EolStashFixture.actor)
        result.changed_paths.should eq([".gitattributes"])
        File.read(File.join(root, "file.txt")).should eq("base\n")
      end
    end

    it "keeps raw #{format} binary and symlink values when replaying converted trees" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root, "* text=auto eol=crlf\n")
        binary = "binary\0\r\n"
        File.write(File.join(root, "file.txt"), binary)
        File.symlink("target\r\n", File.join(root, "link"))
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
        File.read(File.join(root, "file.txt")).should eq(binary)
        File.readlink(File.join(root, "link")).should eq("target\r\n")
      end
    end

    it "refuses raw #{format} EOL-only races during tracked apply publication" do
      GitOracle.with_repo(format: format) do |root|
        repo = EolStashFixture.base(root)
        path = File.join(root, "file.txt")
        File.write(path, "working\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
        changed = false
        check = -> do
          if !changed && File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD"))
            changed = true
            File.write(path, "base\n")
          end
          nil
        end
        error = expect_raises(Git::Stash::PartialApply) do
          repo.stash.apply(actor: EolStashFixture.actor, check: check)
        end
        error.changed_paths.should be_empty
        File.read(path).should eq("base\n")
        repo.refs.resolve?("refs/stash").should eq(entry.oid)
      end
    end

    it "preserves Git's blob-source BOM policy for third-parent #{format} attributes" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "file.txt"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        repo = Git::Repository.new(root)
        attributes = "\uFEFF" + EolStashFixture::CRLF
        File.write(File.join(root, ".gitattributes"), attributes)
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, "new.txt"), "untracked\r\n")
        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("untracked\n")
        GitOracle.run(root, "stash", "apply", "-q")
        expected = File.read(File.join(root, "new.txt"))
        expected.should eq("untracked\n")
        File.delete(File.join(root, ".gitattributes"))
        File.delete(File.join(root, "new.txt"))
        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, "new.txt")).should eq(expected)
        File.read(File.join(root, ".gitattributes")).should eq(attributes)
      end
    end
  end
end
