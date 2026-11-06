require "spec"
require "../src/git"
require "./support/git_oracle"

module EOLReplaySpec
  def self.signature : Git::Signature
    Git::Signature.new("Replay", "replay@example.invalid", 1_700_000_000_i64, 0)
  end

  def self.write(root : String, path : String, bytes : String) : Nil
    Dir.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), bytes)
  end

  def self.commit(root : String, message : String) : String
    GitOracle.run(root, "add", ".")
    GitOracle.run(root, "commit", "-qm", message)
    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
  end

  def self.fixture(root : String, conflict : Bool = false) : String
    write(root, ".gitattributes", "*.txt text eol=crlf\n")
    write(root, "file.txt", "base\r\n")
    commit(root, "base")
    GitOracle.run(root, "checkout", "-qb", "topic")
    write(root, "file.txt", "topic\r\n")
    write(root, "added.txt", "added\r\n")
    commit(root, "topic")
    GitOracle.run(root, "checkout", "-q", "main")
    if conflict
      write(root, "file.txt", "ours\r\n")
      commit(root, "ours")
    end
    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
  end

  def self.blob(repo : Git::Repository, path : String) : String
    entry = repo.index_entries.find { |item| item.path == path && item.stage == 0 }.not_nil!
    repo.read_object(entry.oid).data
  end
end

describe "native replay EOL conversion" do
  ["sha1", "sha256"].each do |format|
    it "matches Git's #{format} cherry-pick and revert materialization" do
      GitOracle.with_repo(format: format) do |root|
        original = EOLReplaySpec.fixture(root)
        GitOracle.run(root, "cherry-pick", "topic")
        expected = File.read(File.join(root, "file.txt"))
        expected_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        GitOracle.run(root, "reset", "--hard", original)
        repo = Git::Repository.new(root)
        picked = repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
        picked.conflicts.should be_empty
        File.read(File.join(root, "file.txt")).should eq(expected)
        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(expected_tree)
        EOLReplaySpec.blob(repo, "file.txt").should eq("topic\n")
        repo.working_changes(include_untracked: false).should be_empty
        repo.revert(picked.commit_oid.not_nil!, author: EOLReplaySpec.signature,
          committer: EOLReplaySpec.signature)
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
        EOLReplaySpec.blob(repo, "file.txt").should eq("base\n")
      end
    end

    ["abort", "skip", "continue"].each do |action|
      it "materializes #{format} conflict markers and #{action} with canonical stages" do
        GitOracle.with_repo(format: format) do |root|
          original = EOLReplaySpec.fixture(root, true)
          repo = Git::Repository.new(root)
          repo.cherry_pick("topic", committer: EOLReplaySpec.signature).conflicts.should eq(["file.txt"])
          marker = File.read(File.join(root, "file.txt"))
          marker.should contain("<<<<<<< HEAD\r\n")
          marker.gsub("\r\n", "").includes?('\n').should be_false
          repo.index_entries.select { |entry| entry.path == "file.txt" }.each do |entry|
            repo.read_object(entry.oid).data.includes?('\r').should be_false
          end
          if action == "continue"
            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
            repo.stage_file("file.txt")
            repo.cherry_pick.continue(committer: EOLReplaySpec.signature)
            EOLReplaySpec.blob(repo, "file.txt").should eq("resolved\n")
          else
            action == "skip" ? repo.cherry_pick.skip : repo.cherry_pick.abort
            File.read(File.join(root, "file.txt")).should eq("ours\r\n")
            File.exists?(File.join(root, "added.txt")).should be_false
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
          end
          repo.sequencer.state?.should be_nil
          repo.working_changes(include_untracked: false).should be_empty
        end
      end
    end

    it "rejects expanded #{format} replay output before metadata or publication" do
      GitOracle.with_repo(format: format) do |root|
        original = EOLReplaySpec.fixture(root)
        GitOracle.run(root, "checkout", "-q", "topic")
        EOLReplaySpec.write(root, "large1.txt", "\n" * 200)
        EOLReplaySpec.write(root, "large2.txt", "\n" * 200)
        EOLReplaySpec.commit(root, "large")
        GitOracle.run(root, "checkout", "-q", "main")
        repo = Git::Repository.new(root)
        index = File.read(File.join(root, ".git/index"))
        expect_raises(Git::Error, /total byte budget/) do
          repo.cherry_pick("topic", committer: EOLReplaySpec.signature,
            max_object_bytes: 512, max_total_bytes: 512_i64)
        end
        File.read(File.join(root, ".git/index")).should eq(index)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        File.exists?(File.join(root, "large1.txt")).should be_false
        repo.sequencer.state?.should be_nil
      end
    end
  end
end
