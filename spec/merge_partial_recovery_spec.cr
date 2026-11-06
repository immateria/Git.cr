require "spec"
require "../src/git"
require "./support/git_oracle"

# Worktree writes precede index publication. Recovery must distinguish those
# exact outputs from unrelated files that appeared after global preflight.
require "./support/merge_partial_recovery"

describe "Git partial directory conflict recovery" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |file_ours|
      MergePartialRecoverySpec::OPERATIONS.each do |operation|
        it "aborts #{format} #{operation} file_ours=#{file_ours} worktree outputs before index publication after reopening" do
          GitOracle.with_repo(format: format) do |root|
            original = MergePartialRecoverySpec.fixture(root, operation, file_ours)
            injected = false
            check = -> do
              if !injected && Dir.children(root).any?(&.starts_with?("node~"))
                injected = true
                raise Git::Error.new("injected recovery failure")
              end
            end
            MergePartialRecoverySpec.expect_partial(operation) do
              MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
            end
            injected.should be_true
            File.exists?(File.join(root, ".git", "index.lock")).should be_false
            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
            MergePartialRecoverySpec.assert_restored(root, operation, original)
          end
        end
      end
    end
  end

  MergePartialRecoverySpec::OPERATIONS.each do |operation|
    it "preserves #{operation} untracked content at an unpublished planned relocation" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, true)
        injected = false
        check = -> do
          if !injected && File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation)))
            injected = true
            File.write(File.join(root, "node~HEAD"), "unrelated arrival\n")
            raise Git::Error.new("injected recovery failure")
          end
        end
        MergePartialRecoverySpec.expect_partial(operation) do
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
        end
        injected.should be_true
        expect_raises(Git::Error) do
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        end
        File.read(File.join(root, "node~HEAD")).should eq("unrelated arrival\n")
        File.read(File.join(root, "node")).should eq("changed\n")
        File.read(File.join(root, "untracked-caller")).should eq("preserve untracked caller\n")
        File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation))).should be_true
        File.delete(File.join(root, "node~HEAD"))
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end

    it "preserves #{operation} changed unindexed relocation bytes and can retry after their removal" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, false)
        check = -> do
          if Dir.children(root).any?(&.starts_with?("node~"))
            raise Git::Error.new("injected recovery failure")
          end
        end
        MergePartialRecoverySpec.expect_partial(operation) do
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
        end
        relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
        File.write(File.join(root, relocated), "caller changed generated content\n")
        expect_raises(Git::Error) do
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        end
        File.read(File.join(root, relocated)).should eq("caller changed generated content\n")
        File.read(File.join(root, "untracked-caller")).should eq("preserve untracked caller\n")
        File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation))).should be_true
        File.delete(File.join(root, relocated))
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end

    it "aborts fully published #{operation} conflicts with legacy path-only relocation metadata" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, true)
        MergePartialRecoverySpec.start(Git::Repository.new(root), operation)
        name = operation == "merge" ? "CRYSTAL_MERGE_PATHS" : "CRYSTAL_SEQUENCER_PATHS"
        original_name = operation == "merge" ? "CRYSTAL_MERGE_ORIG" : "CRYSTAL_SEQUENCER_ORIG"
        original_path = File.join(root, ".git", original_name)
        File.write(original_path, File.read(original_path).lines.first(2).join("\n") + "\n")
        File.write(File.join(root, ".git", name), "node~HEAD")
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end

    it "refuses ambiguous unindexed #{operation} relocations from legacy path-only metadata" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, false)
        check = -> do
          if Dir.children(root).any?(&.starts_with?("node~"))
            raise Git::Error.new("injected recovery failure")
          end
        end
        MergePartialRecoverySpec.expect_partial(operation) do
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
        end
        relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
        contents = File.read(File.join(root, relocated))
        name = operation == "merge" ? "CRYSTAL_MERGE_PATHS" : "CRYSTAL_SEQUENCER_PATHS"
        original_name = operation == "merge" ? "CRYSTAL_MERGE_ORIG" : "CRYSTAL_SEQUENCER_ORIG"
        original_path = File.join(root, ".git", original_name)
        File.write(original_path, File.read(original_path).lines.first(2).join("\n") + "\n")
        File.write(File.join(root, ".git", name), relocated)
        expect_raises(Git::Error) do
          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        end
        File.read(File.join(root, relocated)).should eq(contents)
        File.read(File.join(root, "untracked-caller")).should eq("preserve untracked caller\n")
        File.delete(File.join(root, relocated))
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end

    it "retries #{operation} abort after restoring its original file before index publication" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, true)
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
        File.read(File.join(root, "node")).should eq("changed\n")
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end
  end

  it "preserves an unrelated symlink at an unpublished planned relocation" do
    GitOracle.with_repo do |root|
      original = MergePartialRecoverySpec.fixture(root, "merge", true)
      injected = false
      check = -> do
        if !injected && File.exists?(File.join(root, ".git", "MERGE_HEAD"))
          injected = true
          File.symlink("untracked-caller", File.join(root, "node~HEAD"))
          raise Git::Error.new("injected recovery failure")
        end
      end
      MergePartialRecoverySpec.expect_partial("merge") do
        MergePartialRecoverySpec.start(Git::Repository.new(root), "merge", check)
      end
      expect_raises(Git::Error) do
        MergePartialRecoverySpec.abort(Git::Repository.new(root), "merge")
      end
      File.symlink?(File.join(root, "node~HEAD")).should be_true
      File.readlink(File.join(root, "node~HEAD")).should eq("untracked-caller")
      File.read(File.join(root, "untracked-caller")).should eq("preserve untracked caller\n")
      File.delete(File.join(root, "node~HEAD"))
      MergePartialRecoverySpec.abort(Git::Repository.new(root), "merge")
      MergePartialRecoverySpec.assert_restored(root, "merge", original)
    end
  end
end

describe "Git recovery from an empty structural directory" do
  MergePartialRecoverySpec::OPERATIONS.each do |operation|
    it "restores #{operation} after mkdir but before publishing the child file" do
      GitOracle.with_repo do |root|
        original = MergePartialRecoverySpec.fixture(root, operation, true)
        injected = false
        check = -> do
          if !injected && File.exists?(File.join(root, ".git", MergePartialRecoverySpec.head_name(operation))) &&
             Dir.exists?(File.join(root, "node")) && !File.exists?(File.join(root, "node/child"))
            injected = true
            raise Git::Error.new("injected recovery failure")
          end
        end
        MergePartialRecoverySpec.expect_partial(operation) do
          MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
        end
        injected.should be_true
        MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
        MergePartialRecoverySpec.assert_restored(root, operation, original)
      end
    end
  end
end
