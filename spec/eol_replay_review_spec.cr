require "./eol_replay_spec"
require "./support/merge_partial_recovery"

class Git::Repository
  def eol_test_recovery_maps(predecessor : Hash(String, Git::Checkout::FileState), target : Hash(String, Git::Checkout::FileState), max_entries : Int32) : String
    admin = Git::DescriptorPath::Directory.open(git_dir)
    begin
      replay_recovery!(admin, "review-recovery", "review", predecessor, target,
        max_bytes: 8_388_608, max_entries: max_entries, persist: false)
    ensure
      admin.close
    end
  end
end

module EOLReplayReviewSpec
  def self.fixture(root : String) : String
    EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n")
    EOLReplaySpec.write(root, "file.txt", "base\r\n")
    EOLReplaySpec.commit(root, "base")
    GitOracle.run(root, "checkout", "-qb", "topic")
    EOLReplaySpec.write(root, "file.txt", "topic\r\n")
    EOLReplaySpec.commit(root, "first")
    EOLReplaySpec.write(root, "later.txt", "later\r\n")
    original = EOLReplaySpec.commit(root, "later")
    GitOracle.run(root, "checkout", "-q", "main")
    EOLReplaySpec.write(root, "file.txt", "upstream\r\n")
    EOLReplaySpec.commit(root, "upstream")
    GitOracle.run(root, "checkout", "-q", "topic")
    original
  end
end

describe "replay review boundary regressions" do
  ["sha1", "sha256"].each do |format|
    it "requires #{format} outer restoration provenance after both receipt files disappear" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplayReviewSpec.fixture(root)
        repo = Git::Repository.new(root)
        repo.rebase("main", committer: EOLReplaySpec.signature)
        check = -> do
          if !File.exists?(File.join(root, ".git/REBASE_HEAD")) && File.exists?(File.join(root, "later.txt"))
            raise Git::Error.new("interrupt outer restoration")
          end
        end
        expect_raises(Git::Rebase::PartialPublication) { repo.rebase.abort(committer: EOLReplaySpec.signature, check: check) }
        state_path = File.join(root, ".git/rebase-merge/state")
        state = File.read(state_path)
        receipt = File.join(root, ".git/rebase-merge/worktree-restore")
        File.delete(receipt)
        File.delete("#{receipt}.required")
        EOLReplaySpec.write(root, "later.txt", "later\n")
        EOLReplaySpec.write(root, ".git/info/attributes", "later.txt text eol=lf\n")
        index = File.read(File.join(root, ".git/index"))
        head = GitOracle.run(root, "rev-parse", "HEAD").stdout
        expect_raises(Git::Error, /required.*restoration.*missing/) do
          Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
        end
        File.read(state_path).should eq(state)
        File.read(File.join(root, ".git/index")).should eq(index)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.should eq(head)
        File.read(File.join(root, "later.txt")).should eq("later\n")
        File.exists?(receipt).should be_false
      end
    end

    ["cherry-pick", "revert"].each do |operation|
      it "requires #{format} #{operation} restoration provenance after losing both receipt files" do
        GitOracle.with_repo(format: format) do |root|
          EOLReplaySpec.write(root, ".gitattributes", "* text eol=crlf\n")
          MergePartialRecoverySpec.fixture(root, operation, true)
          GitOracle.run(root, "checkout-index", "--all", "--force")
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation)
          check = -> do
            if File.file?(File.join(root, "node")) && File.exists?(File.join(root, "node~HEAD"))
              raise Git::Error.new("injected recovery failure")
            end
          end
          MergePartialRecoverySpec.expect_partial(operation) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation, check)
          end
          state_path = File.join(root, ".git/CRYSTAL_SEQUENCER_ORIG")
          state = File.read(state_path)
          receipt = File.join(root, ".git/CRYSTAL_SEQUENCER_RESTORE")
          File.delete(receipt)
          File.delete("#{receipt}.required")
          EOLReplaySpec.write(root, "node", "changed\n")
          EOLReplaySpec.write(root, ".git/info/attributes", "* text eol=lf\n")
          index = File.read(File.join(root, ".git/index"))
          expect_raises(Git::Error, /required.*restoration.*missing/) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          end
          File.read(state_path).should eq(state)
          File.read(File.join(root, ".git/index")).should eq(index)
          File.read(File.join(root, "node")).should eq("changed\n")
          File.exists?(receipt).should be_false
        end
      end
    end

    it "rejects #{format} onto expansion before operation metadata or ORIG_HEAD changes" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.write(root, "base", "base\n")
        base = EOLReplaySpec.commit(root, "base")
        GitOracle.run(root, "checkout", "-qb", "topic")
        EOLReplaySpec.write(root, "topic", "topic\n")
        original = EOLReplaySpec.commit(root, "topic")
        GitOracle.run(root, "checkout", "-q", "main")
        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n")
        EOLReplaySpec.write(root, "large1.txt", "\n" * 200)
        EOLReplaySpec.write(root, "large2.txt", "\n" * 200)
        EOLReplaySpec.commit(root, "large onto")
        GitOracle.run(root, "checkout", "-q", "topic")
        orig_head = "#{base}\n"
        File.write(File.join(root, ".git/ORIG_HEAD"), orig_head)
        index = File.read(File.join(root, ".git/index"))
        metadata_seen = false
        check = -> do
          metadata_seen ||= Dir.exists?(File.join(root, ".git/rebase-merge")) ||
                            File.read(File.join(root, ".git/ORIG_HEAD")) != orig_head
        end
        expect_raises(Git::Error, /total byte budget/) do
          Git::Repository.new(root).rebase("main", committer: EOLReplaySpec.signature,
            max_object_bytes: 512, max_total_bytes: 512_i64, check: check)
        end
        metadata_seen.should be_false
        File.read(File.join(root, ".git/ORIG_HEAD")).should eq(orig_head)
        File.read(File.join(root, ".git/index")).should eq(index)
        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
        Dir.exists?(File.join(root, ".git/rebase-merge")).should be_false
        File.exists?(File.join(root, "large1.txt")).should be_false
      end
    end

    it "bounds the #{format} distinct recovery path union while allowing two identities per path" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        first = Git::Checkout::FileState.new("100644", Git::ObjectId.digest("blob", "first\n", repo.object_format))
        second = Git::Checkout::FileState.new("100644", Git::ObjectId.digest("blob", "second\n", repo.object_format))
        expect_raises(Git::Error, /entry budget/) do
          repo.eol_test_recovery_maps({"a" => first}, {"b" => second}, 1)
        end
        repo.eol_test_recovery_maps({"a" => first}, {"a" => second}, 1).should contain(first.oid)
        repo.eol_test_recovery_maps({"a" => first}, {"b" => second}, Int32::MAX).should contain(second.oid)
        File.exists?(File.join(root, ".git/review-recovery")).should be_false
      end
    end
  end
end
