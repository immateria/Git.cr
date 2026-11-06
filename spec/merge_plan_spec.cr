require "spec"
require "../src/git"

# The tree planner is shared by merge and replay; these invariants must not
# diverge when one operation grows new cases or publication policy.
describe Git::Merge do
  it "compares HEAD to the index including stage and policy flags" do
    head = {"file" => Git::Checkout::FileState.new("100644", "blob")}
    clean = Git::Index::Entry.new("file", "100644", "blob", 0, false, false)
    Git::Merge.index_matches_head?([clean], head).should be_true
    Git::Merge.index_matches_head?([clean], {} of String => Git::Checkout::FileState).should be_false
    Git::Merge.index_matches_head?([Git::Index::Entry.new("file", "100644", "blob", 2, false, false)], head).should be_false
    Git::Merge.index_matches_head?([Git::Index::Entry.new("file", "100644", "blob", 0, false, true)], head).should be_false
    Git::Merge.index_matches_head?([Git::Index::Entry.new("file", "100644", "blob", 0, true, false)], head).should be_false
    Git::Merge.index_matches_head?([Git::Index::Entry.new("file", "100644", "blob", 0, false, false, true)], head).should be_false
  end

  it "reconstructs sparse conflict stages without fabricating missing sides" do
    entries = [
      Git::Index::Entry.new("z", "100644", "local", 2, false, false),
      Git::Index::Entry.new("a", "100644", "base", 1, false, false),
      Git::Index::Entry.new("a", "100755", "incoming", 3, false, false),
      Git::Index::Entry.new("ignored", "100644", "merged", 0, false, false),
    ]
    Git::Merge.conflicts_from_entries(entries).should eq([
      Git::Merge::Conflict.new("a", Git::Checkout::FileState.new("100644", "base"), nil,
        Git::Checkout::FileState.new("100755", "incoming")),
      Git::Merge::Conflict.new("z", nil, Git::Checkout::FileState.new("100644", "local"), nil),
    ])
  end

  it "plans file-to-directory transition removals before writes without mutating the index" do
    edits = [] of Git::Index::Edit
    edits << Git::Index::Remove.new("dir")
    edits << Git::Index::Put.new("dir/file", "100644", "new")
    writes = [Git::Checkout::Write.new("dir/file", "100644", "new", "content")]
    removals = [{"dir", Git::Checkout::FileState.new("100644", "old")}]
    plan = Git::Merge::FilePlan.new(edits, writes, removals, [] of String)
    current = [Git::Index::Entry.new("dir", "100644", "old", 0, false, false)]
    plan.final_paths(current).should eq(Set{"dir/file"})
    current.map(&.path).should eq(["dir"])
    blocked, trailing = plan.partition_removals
    blocked.should eq(removals)
    trailing.should be_empty
    plan.validate_symlinks!
  end

  it "rejects an unpublishable symbolic link in a shared plan" do
    writes = [Git::Checkout::Write.new("link", "120000", "blob", "")]
    plan = Git::Merge::FilePlan.new([] of Git::Index::Edit, writes,
      [] of {String, Git::Checkout::FileState}, [] of String)
    expect_raises(Git::Error, "invalid Git symlink target") { plan.validate_symlinks! }
  end
end
