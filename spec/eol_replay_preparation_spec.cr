require "./eol_replay_spec"

class Git::Repository
  def eol_test_prepared_replay(hook : Proc(Array(Git::Index::Entry), Git::Merge::FilePlan, Int64)) : Git::Sequencer::Result
    sequencer_start(Git::Sequencer::Kind::CherryPick, "topic", committer: EOLReplaySpec.signature,
      author: nil, message: nil, mainline: nil, allow_empty: false,
      max_object_bytes: 8_388_608, max_index_bytes: 8_388_608,
      max_total_bytes: 67_108_864_i64, max_entries: 10_000,
      check: nil, prepare_worktree: hook)
  end
end

describe "replay supplemental output preparation" do
  ["sha1", "sha256"].each do |format|
    [-1_i64, 0_i64, 67_108_865_i64].each do |remaining|
      it "checks #{format} hook budget #{remaining} before publication" do
        GitOracle.with_repo(format: format) do |root|
          original = EOLReplaySpec.fixture(root)
          index = File.read(File.join(root, ".git/index"))
          calls = 0
          hook = ->(current : Array(Git::Index::Entry), plan : Git::Merge::FilePlan) do
            calls += 1
            current.any? { |entry| entry.path == "file.txt" }.should be_true
            plan.writes.find { |write| write.path == "file.txt" }.not_nil!.data.should eq("topic\n")
            File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
            remaining
          end
          expect_raises(Git::Error, /byte budget/) { Git::Repository.new(root).eol_test_prepared_replay(hook) }
          calls.should eq(1)
          File.read(File.join(root, ".git/index")).should eq(index)
          File.read(File.join(root, "file.txt")).should eq("base\r\n")
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
          File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
        end
      end
    end

    it "cancels #{format} supplemental preparation before tracked publication" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.fixture(root)
        hook = ->(_current : Array(Git::Index::Entry), _plan : Git::Merge::FilePlan) : Int64 do
          raise Git::Error.new("cancel supplemental output")
        end
        expect_raises(Git::Error, "cancel supplemental output") { Git::Repository.new(root).eol_test_prepared_replay(hook) }
        File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
      end
    end

    it "preserves an index mutation made by the #{format} preparation callback" do
      GitOracle.with_repo(format: format) do |root|
        EOLReplaySpec.fixture(root)
        repo = Git::Repository.new(root)
        hook = ->(_current : Array(Git::Index::Entry), _plan : Git::Merge::FilePlan) do
          repo.stage_blob("callback", "preserve callback index mutation\n")
          67_108_864_i64
        end
        expect_raises(Git::Error, /index changed/) { repo.eol_test_prepared_replay(hook) }
        EOLReplaySpec.blob(repo, "callback").should eq("preserve callback index mutation\n")
        File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
        File.read(File.join(root, "file.txt")).should eq("base\r\n")
      end
    end
  end
end
