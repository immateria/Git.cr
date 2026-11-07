require "./eol_replay_spec"
require "./support/merge_partial_recovery"

describe "converted replay outputs before index publication" do
  ["sha1", "sha256"].each do |format|
    ["cherry-pick", "revert"].each do |operation|
      it "owns only exact #{format} #{operation} relocation bytes after partial replay" do
        GitOracle.with_repo(format: format) do |root|
          EOLReplaySpec.write(root, ".gitattributes", "* text eol=crlf\n")
          original = MergePartialRecoverySpec.fixture(root, operation, false)
          GitOracle.run(root, "checkout-index", "--all", "--force")
          check = -> do
            if Dir.children(root).any?(&.starts_with?("node~"))
              raise Git::Error.new("injected recovery failure")
            end
          end
          MergePartialRecoverySpec.expect_partial(operation) do
            MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
          end
          relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
          output = File.read(File.join(root, relocated))
          output.should contain("\r\n")
          EOLReplaySpec.write(root, relocated, output.gsub("\r\n", "\n"))
          expect_raises(Git::Error, /untracked|changed/) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          end
          File.read(File.join(root, relocated)).should eq(output.gsub("\r\n", "\n"))
          EOLReplaySpec.write(root, relocated, output)
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original[0])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(original[1])
          File.read(File.join(root, "node-sibling")).should eq("preserve tracked sibling\r\n")
          Dir.children(root).select(&.starts_with?("node~")).should be_empty
        end
      end

      it "pins #{format} #{operation} original conversion identities across interrupted abort" do
        GitOracle.with_repo(format: format) do |root|
          EOLReplaySpec.write(root, ".gitattributes", "* text eol=crlf\n")
          original = MergePartialRecoverySpec.fixture(root, operation, true)
          GitOracle.run(root, "checkout-index", "--all", "--force")
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation)
          injected = false
          check = -> do
            if !injected && File.file?(File.join(root, "node")) && File.exists?(File.join(root, "node~HEAD"))
              injected = true
              raise Git::Error.new("injected recovery failure")
            end
          end
          MergePartialRecoverySpec.expect_partial(operation) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation, check)
          end
          injected.should be_true
          File.read(File.join(root, "node")).should eq("changed\r\n")
          EOLReplaySpec.write(root, "node", "changed\n")
          EOLReplaySpec.write(root, ".git/info/attributes", "* text eol=lf\n")
          expect_raises(Git::Error, /identities changed/) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          end
          File.read(File.join(root, "node")).should eq("changed\n")
          File.delete(File.join(root, ".git/info/attributes"))
          expect_raises(Git::Error, /untracked|changed/) do
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          end
          EOLReplaySpec.write(root, "node", "changed\r\n")
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original[0])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(original[1])
          File.read(File.join(root, "node")).should eq("changed\r\n")
          File.exists?(File.join(root, ".git/CRYSTAL_SEQUENCER_RESTORE")).should be_false
        end
      end
    end
  end
end
