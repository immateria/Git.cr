require "spec"
require "../src/git"
require "./support/merge_partial_recovery"

describe "Git interrupted outer rebase abort" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |file_ours|
      ["worktree", "reference"].each do |phase|
        it "retries #{format} file_ours=#{file_ours} after partial #{phase} restoration" do
          GitOracle.with_repo(format: format) do |root|
            original = MergePartialRecoverySpec.fixture(root, "rebase", file_ours)
            MergePartialRecoverySpec.start(Git::Repository.new(root), "rebase")
            injected = false
            check = -> do
              unless injected || File.exists?(File.join(root, ".git", "REBASE_HEAD"))
                head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
                interrupted = if phase == "reference"
                                head == original[0]
                              elsif file_ours
                                Dir.exists?(File.join(root, "node")) && !File.exists?(File.join(root, "node/child"))
                              else
                                !File.exists?(File.join(root, "node"))
                              end
                if interrupted
                  injected = true
                  raise Git::Error.new("injected outer abort failure")
                end
              end
            end
            error = expect_raises(Git::Rebase::PartialPublication) do
              MergePartialRecoverySpec.abort(Git::Repository.new(root), "rebase", check)
            end
            error.original_error.message.should eq("injected outer abort failure")
            injected.should be_true
            Git::Repository.new(root).rebase.state?.should_not be_nil
            if phase == "reference"
              # The restored output is still unindexed; the sibling remains
              # indexed. Neither admission route may erase later caller edits.
              [file_ours ? "node/child" : "node", "node-sibling"].each do |path|
                absolute = File.join(root, path)
                saved = File.read(absolute)
                index = GitOracle.run(root, "ls-files", "-s").stdout
                File.write(absolute, "caller edit after interrupted abort\n")
                expect_raises(Git::Error) { MergePartialRecoverySpec.abort(Git::Repository.new(root), "rebase") }
                File.read(absolute).should eq("caller edit after interrupted abort\n")
                GitOracle.run(root, "ls-files", "-s").stdout.should eq(index)
                Git::Repository.new(root).rebase.state?.should_not be_nil
                File.write(absolute, saved)
              end
            end
            MergePartialRecoverySpec.abort(Git::Repository.new(root), "rebase")
            MergePartialRecoverySpec.assert_restored(root, "rebase", original)
          end
        end
      end
    end
  end
end
