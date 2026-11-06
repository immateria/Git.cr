require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git two-source rename collision composition" do
  ["sha1", "sha256"].each do |format|
    [false, true].each do |edit_moved|
      [false, true].each do |swap|
        it "preserves #{format} both source edits edit_moved=#{edit_moved} swap=#{swap}" do
          GitOracle.with_repo(format: format) do |root|
            first = (0...20).map { |i| "first #{i}: original\n" }.join
            second = (0...20).map { |i| "second #{i}: original\n" }.join
            File.write(File.join(root, "first"), first)
            File.write(File.join(root, "second"), second)
            GitOracle.run(root, "add", ".")
            GitOracle.run(root, "commit", "-qm", "base")
            GitOracle.run(root, "checkout", "-qb", "topic")
            GitOracle.run(root, "mv", "second", "destination")
            File.write(File.join(root, "first"), first.sub("first 15:", "incoming edit:"))
            File.write(File.join(root, "destination"), second.sub("second 2:", "incoming moved edit:")) if edit_moved
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "topic")
            GitOracle.run(root, "checkout", "-q", "main")
            GitOracle.run(root, "mv", "first", "destination")
            File.write(File.join(root, "second"), second.sub("second 15:", "local edit:"))
            File.write(File.join(root, "destination"), first.sub("first 2:", "local moved edit:")) if edit_moved
            GitOracle.run(root, "add", "-A")
            GitOracle.run(root, "commit", "-qm", "main")
            GitOracle.run(root, "checkout", "-q", "topic") if swap
            incoming = swap ? "main" : "topic"
            GitOracle.run(root, "merge", "--no-commit", "--no-ff", incoming, check: false).exit_code.should eq(1)
            expected_index = GitOracle.run(root, "ls-files", "-s").stdout
            expected_content = File.read(File.join(root, "destination"))
            GitOracle.run(root, "merge", "--abort")
            repo = Git::Repository.new(root)
            sig = Git::Signature.new("Quality", "quality@example.test", 1234567890_i64, 0)
            repo.merge(incoming, author: sig, committer: sig, message: "merge").conflicts.should eq(["destination"])
            GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
            File.read(File.join(root, "destination")).should eq(expected_content)
            repo.merge.abort
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
        end
      end
    end
  end
end
