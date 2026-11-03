require "spec"
require "../src/git"

describe "Git semantic owners" do
  it "exposes distinct index and working-tree values through the default import" do
    oid = "a" * 40
    entry = Git::Index::Entry.new("docs/readme.txt", "100644", oid, 0, false, false)
    entry.stage.should eq(0)
    staged = Git::Index::Change.new("docs/readme.txt", "modified", nil, oid, 0, nil, "100644")
    staged.to_json.should contain(%("index_oid":"#{oid}"))
    staged.to_json.should contain(%("status":"modified"))
    working = Git::WorkingTree::Change.new("docs/readme.txt", "deleted", oid, nil)
    working.to_json.should contain(%("worktree_oid":null))
    staged.class.name.should_not eq(working.class.name)
  end

  it "keeps file comparisons owned by the side being compared" do
    old_oid = "b" * 40
    new_oid = "c" * 40
    staged = Git::Index::FileComparison.new("a.txt", old_oid, new_oid,
      "100644", "100644", "before\n", "after\n")
    working = Git::WorkingTree::FileComparison.new("a.txt", old_oid, new_oid,
      "100644", "100644", "before\n", "after\n")
    staged.new_oid.should eq(working.new_oid)
    staged.class.name.should_not eq(working.class.name)
  end

  it "exposes repository and object storage owners without a host dependency" do
    Git::Repository.name.should eq("Git::Repository")
    Git::ObjectDatabase.name.should eq("Git::ObjectDatabase")
    Git::ObjectDatabase::PackFiles.name.should eq("Git::ObjectDatabase::PackFiles")
    Git::HeadTree.name.should eq("Git::HeadTree")
    Git::Repository::Admission::Identity.new("1000").owns?("1000").should be_true
  end

  it "preserves read-only effective config and provenance on the public result" do
    config = Git::Config.load([] of Git::Config::Source,
      commands: [{"demo.flag", "true"}, {"demo.flag", "false"}])
    config.values("demo.flag").should eq(["true", "false"])
    config.boolean?("demo.flag").should be_false
    config.effective_entry?("demo.flag").not_nil!.scope.should eq(Git::Config::Scope::Command)
  end
end
