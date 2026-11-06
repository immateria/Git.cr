require "./eol_replay_spec"

module EOLReplaySpec
  def self.rebase_fixture(root : String, attributes : Bool = true) : String
    ending = attributes ? "\r\n" : "\n"
    write(root, ".gitattributes", "*.txt text eol=crlf\n") if attributes
    write(root, "file.txt", "base#{ending}")
    commit(root, "base")
    GitOracle.run(root, "checkout", "-qb", "topic")
    write(root, "file.txt", "topic#{ending}")
    commit(root, "first")
    write(root, "later.txt", "later#{ending}")
    original = commit(root, "later")
    GitOracle.run(root, "checkout", "-q", "main")
    write(root, "file.txt", "upstream#{ending}")
    write(root, "upstream.txt", "upstream#{ending}")
    commit(root, "upstream")
    GitOracle.run(root, "checkout", "-q", "topic")
    original
  end
end

describe "native replay raw recovery" do
  ["sha1", "sha256"].each do |format|
    ["continue", "skip"].each do |action|
      it "forwards explicit #{format} conversion config to rebase #{action} and later items" do
        GitOracle.with_repo(format: format) do |root|
          EOLReplaySpec.rebase_fixture(root, false)
          repo = Git::Repository.new(root)
          config = repo.config(command_values: [{"core.autocrlf", "true"}])
          repo.rebase("main", committer: EOLReplaySpec.signature, config: config)
          File.read(File.join(root, "upstream.txt")).should eq("upstream\r\n")
          if action == "continue"
            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
            repo.stage_file("file.txt", config: config)
            repo.rebase.continue(committer: EOLReplaySpec.signature, config: config)
          else
            repo.rebase.skip(committer: EOLReplaySpec.signature, config: config)
          end
          File.read(File.join(root, "later.txt")).should eq("later\r\n")
          EOLReplaySpec.blob(repo, "later.txt").should eq("later\n")
        end
      end
    end

    ["continue", "skip", "abort"].each do |action|
      it "uses #{format} CRLF bytes through rebase onto and #{action}" do
        GitOracle.with_repo(format: format) do |root|
          original = EOLReplaySpec.rebase_fixture(root)
          repo = Git::Repository.new(root)
          repo.rebase("main", committer: EOLReplaySpec.signature).completed.should be_false
          File.read(File.join(root, "upstream.txt")).should eq("upstream\r\n")
          File.read(File.join(root, "file.txt")).should contain("<<<<<<< HEAD\r\n")
          case action
          when "continue"
            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
            repo.stage_file("file.txt")
            repo.rebase.continue(committer: EOLReplaySpec.signature).completed.should be_true
            EOLReplaySpec.blob(repo, "file.txt").should eq("resolved\n")
            File.read(File.join(root, "later.txt")).should eq("later\r\n")
          when "skip"
            repo.rebase.skip(committer: EOLReplaySpec.signature).completed.should be_true
            File.read(File.join(root, "file.txt")).should eq("upstream\r\n")
            File.read(File.join(root, "later.txt")).should eq("later\r\n")
          else
            repo.rebase.abort(committer: EOLReplaySpec.signature)
            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
            File.read(File.join(root, "file.txt")).should eq("topic\r\n")
            File.read(File.join(root, "later.txt")).should eq("later\r\n")
          end
          repo.rebase.state?.should be_nil
          repo.working_changes(include_untracked: false).should be_empty
        end
      end
    end

    ["worktree", "reference"].each do |phase|
      it "binds interrupted #{format} outer abort #{phase} to persisted raw identities" do
        GitOracle.with_repo(format: format) do |root|
          original = EOLReplaySpec.rebase_fixture(root)
          repo = Git::Repository.new(root)
          repo.rebase("main", committer: EOLReplaySpec.signature)
          injected = false
          check = -> do
            if !injected && !File.exists?(File.join(root, ".git/REBASE_HEAD"))
              restored = if phase == "reference"
                           GitOracle.run(root, "rev-parse", "HEAD").stdout.strip == original
                         else
                           File.exists?(File.join(root, "later.txt"))
                         end
              if restored
                injected = true
                raise Git::Error.new("interrupt converted outer abort")
              end
            end
          end
          error = expect_raises(Git::Rebase::PartialPublication) do
            repo.rebase.abort(committer: EOLReplaySpec.signature, check: check)
          end
          injected.should be_true
          error.original_error.message.should eq("interrupt converted outer abort")
          receipt_path = File.join(root, ".git/rebase-merge/worktree-restore")
          receipt = File.read(receipt_path)
          File.read(File.join(root, "later.txt")).should eq("later\r\n")
          index = File.read(File.join(root, ".git/index"))
          # Changing both an unindexed output and retry-time attributes must
          # never turn a clean-equivalent replacement into owned output.
          EOLReplaySpec.write(root, "later.txt", "later\n")
          EOLReplaySpec.write(root, ".git/info/attributes", "*.txt text eol=lf\n")
          expect_raises(Git::Error, /identities changed/) do
            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
          end
          File.read(File.join(root, "later.txt")).should eq("later\n")
          File.read(receipt_path).should eq(receipt)
          File.read(File.join(root, ".git/index")).should eq(index)
          File.delete(File.join(root, ".git/info/attributes"))
          expect_raises(Git::Error, /changed|untracked/) do
            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
          end
          EOLReplaySpec.write(root, "later.txt", "later\r\n")
          # A missing versioned receipt fails closed as well.
          File.delete(receipt_path)
          expect_raises(Git::Error, /required.*missing/) do
            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
          end
          File.write(receipt_path, receipt)
          Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          Dir.exists?(File.join(root, ".git/rebase-merge")).should be_false
        end
      end
    end

    it "refuses a clean-equivalent #{format} EOL race after replay metadata" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.fixture(root)
        injected = false
        check = -> do
          if !injected && File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD"))
            injected = true
            EOLReplaySpec.write(root, "file.txt", "base\n")
          end
        end
        error = expect_raises(Git::Sequencer::PartialPublication) do
          Git::Repository.new(root).cherry_pick("topic", committer: EOLReplaySpec.signature, check: check)
        end
        injected.should be_true
        error.index_published.should be_false
        File.read(File.join(root, "file.txt")).should eq("base\n")
      end
    end
  end
end
