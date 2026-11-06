require "./eol_replay_spec"

describe "native replay attribute sources" do
  ["sha1", "sha256"].each do |format|
    ["incoming", "deleted", "conflicted", "nested"].each do |source|
      it "matches Git's #{format} #{source} planned attributes" do
        GitOracle.with_repo(format: format) do |root|
          attr = source == "nested" ? "nested/.gitattributes" : ".gitattributes"
          file = source == "nested" ? "nested/file.txt" : "file.txt"
          initial = source == "deleted" ? "*.txt text eol=crlf\n" : "*.txt text eol=lf\n"
          EOLReplaySpec.write(root, attr, initial)
          EOLReplaySpec.write(root, file, "base\n")
          EOLReplaySpec.commit(root, "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          if source == "deleted"
            GitOracle.run(root, "rm", attr)
          else
            EOLReplaySpec.write(root, attr, "*.txt text eol=crlf\n# topic\n")
          end
          EOLReplaySpec.write(root, file, "incoming\n")
          EOLReplaySpec.commit(root, "incoming")
          GitOracle.run(root, "checkout", "-q", "main")
          if source == "conflicted"
            EOLReplaySpec.write(root, attr, "*.txt text eol=lf\n# ours\n")
            EOLReplaySpec.commit(root, "ours")
          end
          original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
          oracle = GitOracle.run(root, "cherry-pick", "topic", check: false)
          oracle.success?.should eq(source != "conflicted")
          expected = File.read(File.join(root, file))
          if source == "conflicted"
            GitOracle.run(root, "cherry-pick", "--abort")
          else
            GitOracle.run(root, "reset", "--hard", original)
          end
          repo = Git::Repository.new(root)
          result = repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
          File.read(File.join(root, file)).should eq(expected)
          EOLReplaySpec.blob(repo, file).should eq("incoming\n")
          result.conflicts.should eq(source == "conflicted" ? [attr] : [] of String)
          if source == "conflicted"
            repo.cherry_pick.abort
            File.read(File.join(root, file)).should eq("base\n")
          end
        end
      end
    end

    it "preserves #{format} binary, symlink and unchanged canonical files" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=lf\n*.bin text=auto\nraw.txt -text\n")
        EOLReplaySpec.write(root, "unchanged.txt", "same\n")
        EOLReplaySpec.commit(root, "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n*.bin text=auto\nraw.txt -text\n")
        EOLReplaySpec.write(root, "binary.bin", "binary\0\r\n")
        EOLReplaySpec.write(root, "raw.txt", "raw\r\n")
        File.symlink("target\n", File.join(root, "link.txt"))
        EOLReplaySpec.commit(root, "source")
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
        File.read(File.join(root, "unchanged.txt")).should eq("same\n")
        File.read(File.join(root, "binary.bin")).should eq("binary\0\r\n")
        File.read(File.join(root, "raw.txt")).should eq("raw\r\n")
        File.readlink(File.join(root, "link.txt")).should eq("target\n")
      end
    end

    it "propagates explicit #{format} conversion config through replay and abort" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.write(root, "file", "base\n")
        EOLReplaySpec.commit(root, "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        EOLReplaySpec.write(root, "file", "topic\n")
        EOLReplaySpec.write(root, "added", "added\n")
        EOLReplaySpec.commit(root, "source")
        GitOracle.run(root, "checkout", "-q", "main")
        EOLReplaySpec.write(root, "file", "ours\n")
        EOLReplaySpec.commit(root, "ours")
        repo = Git::Repository.new(root)
        config = repo.config(command_values: [{"core.autocrlf", "true"}])
        repo.cherry_pick("topic", committer: EOLReplaySpec.signature, config: config)
        File.read(File.join(root, "file")).should contain("<<<<<<< HEAD\r\n")
        File.read(File.join(root, "added")).should eq("added\r\n")
        repo.cherry_pick.abort(config: config)
        File.read(File.join(root, "file")).should eq("ours\r\n")
      end
    end

    it "keeps unchanged #{format} canonical files intact during the rebase onto movement" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=lf\n")
        EOLReplaySpec.write(root, "unchanged.txt", "same\n")
        EOLReplaySpec.commit(root, "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        EOLReplaySpec.write(root, "new.txt", "new\n")
        EOLReplaySpec.commit(root, "new")
        GitOracle.run(root, "checkout", "-q", "main")
        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n")
        EOLReplaySpec.commit(root, "attributes")
        GitOracle.run(root, "checkout", "-q", "topic")
        repo = Git::Repository.new(root)
        repo.rebase("main", committer: EOLReplaySpec.signature).completed.should be_true
        File.read(File.join(root, "unchanged.txt")).should eq("same\n")
        File.read(File.join(root, "new.txt")).should eq("new\r\n")
      end
    end
  end
end
