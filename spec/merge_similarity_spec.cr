require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git edited-file rename merging" do
  sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      ["merge", "cherry-pick", "rebase"].each do |operation|
        it "combines #{format} #{operation} rename+edit with independent changes rename_ours=#{rename_ours}" do
          GitOracle.with_repo(format: format) do |root|
            original = (0...20).map { |i| "line #{i}: stable content\n" }
            File.write(File.join(root, "old"), original.join)
            GitOracle.run(root, "add", ".")
            GitOracle.run(root, "commit", "-qm", "base")
            GitOracle.run(root, "checkout", "-qb", "topic")
            if rename_ours
              File.write(File.join(root, "old"), original.map_with_index { |line, i| i == 15 ? "other edit\n" : line }.join)
            else
              GitOracle.run(root, "mv", "old", "new")
              File.write(File.join(root, "new"), original.map_with_index { |line, i| i == 2 ? "rename edit\n" : line }.join)
            end
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "topic")
            source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            GitOracle.run(root, "checkout", "-q", "main")
            if rename_ours
              GitOracle.run(root, "mv", "old", "new")
              File.write(File.join(root, "new"), original.map_with_index { |line, i| i == 2 ? "rename edit\n" : line }.join)
            else
              File.write(File.join(root, "old"), original.map_with_index { |line, i| i == 15 ? "other edit\n" : line }.join)
            end
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "main")
            GitOracle.run(root, "checkout", "-q", "topic") if operation == "rebase"
            old_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            args = case operation
                   when "merge"       then ["merge", "--no-commit", "--no-ff", "topic"]
                   when "cherry-pick" then ["cherry-pick", source]
                   else                    ["rebase", "main"]
                   end
            GitOracle.run_args(root, args).success?.should be_true
            expected_tree = GitOracle.run(root, "write-tree").stdout.strip
            expected_content = File.read(File.join(root, "new"))
            if operation == "merge"
              GitOracle.run(root, "merge", "--abort")
            else
              GitOracle.run(root, "reset", "--hard", old_head)
            end
            repo = Git::Repository.new(root)
            case operation
            when "merge"
              repo.merge("topic", author: sig, committer: sig, message: "merge").conflicts.should be_empty
            when "cherry-pick"
              repo.cherry_pick(source, committer: sig).conflicts.should be_empty
            else
              repo.rebase("main", committer: sig).completed.should be_true
            end
            GitOracle.run(root, "write-tree").stdout.strip.should eq(expected_tree)
            File.read(File.join(root, "new")).should eq(expected_content)
            File.exists?(File.join(root, "old")).should be_false
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
        end
      end
    end
  end
end

describe "Git rename detection work limits" do
  it "bounds signature bytes across both sides" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      left = repo.write_blob("a" * 100)
      right = repo.write_blob("a" * 64 + "b" * 36)
      base = {"old" => Git::Checkout::FileState.new("100644", left)}
      side = {"new" => Git::Checkout::FileState.new("100644", right)}
      detector = Git::Merge::Similarity.new(repo, 1024, 150_i64, nil)
      expect_raises(Git::Error, /similarity byte budget/) { detector.find(base, side, {} of String => String, base) }
    end
  end

  it "bounds candidate comparisons independently of signature caching" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      left = Git::Checkout::FileState.new("100644", repo.write_blob("a" * 100))
      right = Git::Checkout::FileState.new("100644", repo.write_blob("a" * 64 + "b" * 36))
      base = (0...1001).to_h { |i| {"old#{i}", left} }
      side = (0...1000).to_h { |i| {"new#{i}", right} }
      detector = Git::Merge::Similarity.new(repo, 1024, 1024_i64, nil)
      expect_raises(Git::Error, /similarity comparison budget/) { detector.find(base, side, {} of String => String, base) }
    end
  end

  it "polls cancellation while scanning a blob" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      state = Git::Checkout::FileState.new("100644", repo.write_blob("a" * 100_000))
      count = 0
      check = -> do
        count += 1
        raise Git::Error.new("cancelled similarity scan") if count > 10
        nil
      end
      detector = Git::Merge::Similarity.new(repo, 200_000, 200_000_i64, check)
      expect_raises(Git::Error, /cancelled similarity scan/) do
        detector.find({"old" => state}, {"new" => state}, {} of String => String, {"old" => state})
      end
    end
  end
end

describe "Git inverse edited rename replay" do
  ["sha1", "sha256"].each do |format|
    it "reverts a #{format} edited rename while preserving a later independent edit" do
      GitOracle.with_repo(format: format) do |root|
        original = (0...20).map { |i| "line #{i}: stable content\n" }.join
        File.write(File.join(root, "new"), original.sub("line 2:", "rename edit:"))
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "mv", "new", "old")
        File.write(File.join(root, "old"), original)
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "to revert")
        source = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        File.write(File.join(root, "old"), original.sub("line 15:", "later edit:"))
        GitOracle.run(root, "add", "-A")
        GitOracle.run(root, "commit", "-qm", "later")
        ours = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "revert", "--no-edit", source)
        expected = GitOracle.run(root, "write-tree").stdout.strip
        GitOracle.run(root, "reset", "--hard", ours)
        sig = Git::Signature.new("R", "r@example.test", 1234567890_i64, 0)
        repo = Git::Repository.new(root)
        repo.revert(source, author: sig, committer: sig).conflicts.should be_empty
        GitOracle.run(root, "write-tree").stdout.strip.should eq(expected)
        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
      end
    end
  end
end
