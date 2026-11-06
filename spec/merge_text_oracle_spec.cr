require "spec"
require "../src/git"
require "./support/git_oracle"

# Compare the native bounded line combiner with the pinned Git merge-file
# oracle. The unique-line fixtures avoid the separate repeated-line LCS case.
describe "bounded text merge oracle parity" do
  base = "a\nb\nc\nd\ne\nf\n"
  cases = [
    {"unchanged ours", base, base, "a\nb\nC\nd\ne\nf\n"},
    {"unchanged theirs", base, "a\nB\nc\nd\ne\nf\n", base},
    {"same change", base, "a\nB\nc\nd\ne\nf\n", "a\nB\nc\nd\ne\nf\n"},
    {"separated replacements", base, "a\nB\nc\nd\ne\nf\n", "a\nb\nc\nd\nE\nf\n"},
    {"adjacent replacements", base, "a\nB\nc\nd\ne\nf\n", "a\nb\nC\nd\ne\nf\n"},
    {"adjacent deletions", base, "a\nc\nd\ne\nf\n", "a\nb\nd\ne\nf\n"},
    {"adjacent replace and delete", base, "a\nB\nc\nd\ne\nf\n", "a\nb\nd\ne\nf\n"},
    {"overlapping replacements", base, "a\nB\nC\nd\ne\nf\n", "a\nb\nY\nd\ne\nf\n"},
    {"identical insertion", base, "a\nb\nC\nc\nd\ne\nf\n", "a\nb\nC\nc\nd\ne\nf\n"},
    {"separated insertion", base, "a\nA\nb\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\nE\nf\n"},
    {"insertion at edit boundary", base, "a\nB\nc\nd\ne\nf\n", "a\nb\nINSERT\nc\nd\ne\nf\n"},
  ]
  cases.each do |name, original, ours, theirs|
    it "M1 #{name}" do
      GitOracle.with_repo do |root|
        base_path = File.join(root, "base.txt")
        ours_path = File.join(root, "ours.txt")
        theirs_path = File.join(root, "theirs.txt")
        File.write(base_path, original)
        File.write(ours_path, ours)
        File.write(theirs_path, theirs)
        oracle = GitOracle.run(root, "merge-file", "-p", ours_path, base_path, theirs_path, check: false)
        oracle.exit_code.should be <= 1
        native = Git::Merge::Text.merge(original, ours, theirs)
        if oracle.success?
          native.should eq(oracle.stdout)
        else
          native.should be_nil
        end
      end
    end
  end
end
