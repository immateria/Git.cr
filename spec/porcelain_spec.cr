require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private SIG = Git::Signature.new("Porcelain", "porcelain@example.invalid", 1_700_000_000_i64, 0)

private def at(time : Int64) : Hash(String, String)
  {"GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"}
end

private def commit_file(root : String, name : String, text : String, time : Int64) : String
  path = File.join(root, name)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, text)
  GitOracle.run(root, "add", name)
  GitOracle.run(root, "commit", "-qm", "#{name}: #{text.strip}", extra_env: at(time))
  GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
end

# main with a merge of topic, a tag, reflogs and an upstream.
private def porcelain_history(root : String) : Nil
  GitOracle.run(root, "config", "core.logAllRefUpdates", "true")
  commit_file(root, "src/main.cr", "one\n", 1_700_000_000)
  commit_file(root, "README.md", "readme\n", 1_700_000_100)
  GitOracle.run(root, "checkout", "-q", "-b", "topic")
  commit_file(root, "topic.txt", "topic\n", 1_700_000_200)
  commit_file(root, "topic.txt", "topic 2\n", 1_700_000_300)
  GitOracle.run(root, "checkout", "-q", "main")
  commit_file(root, "src/main.cr", "two\n", 1_700_000_400)
  GitOracle.run(root, "merge", "-q", "--no-ff", "-m", "merge topic", "topic", extra_env: at(1_700_000_500))
  commit_file(root, "after.txt", "after\n", 1_700_000_600)
  GitOracle.run(root, "tag", "-a", "v1", "-m", "v1\n", "HEAD~1", extra_env: at(1_700_000_700))
  GitOracle.run(root, "tag", "light", "HEAD~2")
  GitOracle.run(root, "update-ref", "refs/remotes/origin/main", "HEAD~1")
  GitOracle.run(root, "config", "remote.origin.url", "/nowhere")
  GitOracle.run(root, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
  GitOracle.run(root, "config", "branch.main.remote", "origin")
  GitOracle.run(root, "config", "branch.main.merge", "refs/heads/main")
end

describe "Git porcelain" do
  it "PORCELAIN-O01 resolves revisions like git rev-parse --verify" do
    GitOracle.with_repo do |root|
      porcelain_history(root)
      repo = Git::Repository.new(root)
      short = GitOracle.run(root, "rev-parse", "--short=7", "HEAD~2").stdout.strip
      expressions = ["HEAD", "@", "main", "main~2", "HEAD~1^2", "HEAD~1^2~1", "HEAD^^", "v1", "v1^{}", "v1^{commit}",
                     "v1^{tree}", "light", "HEAD:src/main.cr", "HEAD:src", "HEAD:", "main~1:topic.txt", ":README.md",
                     short, "#{short}~1", "main@{u}", "@{upstream}", "main@{0}", "main@{2}", "HEAD@{1}",
                     "refs/heads/topic", "heads/topic", "topic~1", "v1^{tag}", "HEAD^0"]
      expressions.each do |expression|
        expected = GitOracle.run(root, "rev-parse", "--verify", "-q", expression).stdout.strip
        {expression, repo.rev_parse(expression)}.should eq({expression, expected})
      end
      ["nothing", "HEAD~20", "HEAD^3", "HEAD:missing", "v1^{blob}", "main@{99}", "topic@{u}", "deadbeef"].each do |bad|
        GitOracle.run(root, "rev-parse", "--verify", "-q", bad, check: false).success?.should be_false
        expect_raises(Git::Error) { repo.rev_parse(bad) }
      end
    end
  end

  it "PORCELAIN-O02 lists revision ranges like git rev-list and git log" do
    GitOracle.with_repo do |root|
      porcelain_history(root)
      repo = Git::Repository.new(root)
      [["main"], ["main~3..main"], ["topic..main"], ["topic...main"], ["^topic", "main"], ["main..topic"], ["..main"]].each do |revisions|
        expected = GitOracle.run_args(root, ["rev-list"] + revisions).stdout.lines
        {revisions, repo.rev_list(revisions)}.should eq({revisions, expected})
      end
      repo.log(["main"], limit: 2).map(&.subject).should eq(["after.txt: after", "merge topic"])
      counts = GitOracle.run(root, "rev-list", "--left-right", "--count", "main...topic~1").stdout.split.map(&.to_i)
      repo.ahead_behind("main", "topic~1").should eq({counts[0], counts[1]})
    end
  end

  it "PORCELAIN-O03 lists, deletes and renames branches and tags like git branch and git tag" do
    GitOracle.with_repo do |root|
      porcelain_history(root)
      repo = Git::Repository.new(root)
      GitOracle.run(root, "branch", "merged", "HEAD~2")
      GitOracle.run(root, "checkout", "-q", "-b", "unmerged", "HEAD~1")
      commit_file(root, "unmerged.txt", "x\n", 1_700_001_000)
      GitOracle.run(root, "checkout", "-q", "main")
      GitOracle.run(root, "config", "branch.unmerged.description", "work in progress")

      info = repo.branches.list.to_h { |branch| {branch.name, branch} }
      info.keys.should eq(["main", "merged", "topic", "unmerged"])
      info["main"].current?.should be_true
      info["main"].tracking_ref.should eq("refs/remotes/origin/main")
      info["main"].upstream.should eq(Git::Branch::Upstream.new("origin", "refs/heads/main"))
      counts = GitOracle.run(root, "rev-list", "--left-right", "--count", "main...origin/main").stdout.split.map(&.to_i)
      {info["main"].ahead, info["main"].behind}.should eq({counts[0], counts[1]})

      repo.branches.delete("merged")
      GitOracle.run(root, "rev-parse", "--verify", "-q", "refs/heads/merged", check: false).success?.should be_false
      expect_raises(Git::Error, /not fully merged/) { repo.branches.delete("unmerged") }
      expect_raises(Git::Error, /checked-out/) { repo.branches.delete("main", force: true) }

      repo.branches.rename("unmerged", "renamed")
      GitOracle.run(root, "config", "branch.renamed.description").stdout.strip.should eq("work in progress")
      GitOracle.run(root, "reflog", "show", "--format=%H", "refs/heads/renamed").stdout.lines.size.should be > 0
      repo.branches.rename("main", "trunk")
      GitOracle.run(root, "symbolic-ref", "HEAD").stdout.strip.should eq("refs/heads/trunk")
      GitOracle.run(root, "config", "branch.trunk.merge").stdout.strip.should eq("refs/heads/main")
      expect_raises(Git::Error, /already exists/) { repo.branches.rename("renamed", "topic") }
      repo.branches.delete("renamed", force: true)
      GitOracle.run(root, "config", "--get-regexp", "branch\\.renamed", check: false).success?.should be_false

      repo.tags.list.map(&.short_name).should eq(["light", "v1"])
      repo.tags.delete("light")
      GitOracle.run(root, "tag", "-l").stdout.should eq("v1\n")
      GitOracle.run(root, "fsck", "--no-dangling")
    end
  end

  it "PORCELAIN-O04 pulls by fast-forward or merge" do
    GitOracle.with_repo do |root|
      porcelain_history(root)
      base = File.dirname(root)
      upstream = File.join(base, "upstream.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", root, upstream)
      clone = File.join(base, "clone")
      repo = Git::Repository.clone(upstream, clone)

      writer = File.join(base, "writer")
      GitOracle.run(base, "clone", "-q", upstream, writer)
      ahead = commit_file(writer, "upstream.txt", "new upstream\n", 1_700_002_000)
      GitOracle.run(writer, "push", "-q", "origin", "main")
      pulled = repo.pull(actor: SIG)
      pulled.action.should eq(Git::Pull::Action::FastForward)
      repo.head.oid.should eq(ahead)
      File.read(File.join(clone, "upstream.txt")).should eq("new upstream\n")
      repo.pull.action.should eq(Git::Pull::Action::UpToDate)

      commit_file(writer, "upstream.txt", "newer upstream\n", 1_700_003_000)
      GitOracle.run(writer, "push", "-q", "origin", "main")
      File.write(File.join(clone, "local.txt"), "local\n")
      repo.stage_file("local.txt")
      local = repo.commit(author: SIG, committer: SIG, message: "local\n")
      expect_raises(Git::Error, /diverged/) { repo.pull }
      merged = repo.pull(mode: Git::Pull::Mode::Merge, author: SIG)
      merged.action.should eq(Git::Pull::Action::Merge)
      parents = GitOracle.run(clone, "rev-list", "--parents", "-n", "1", "HEAD").stdout.split
      parents[1..].should eq([local, GitOracle.run(writer, "rev-parse", "HEAD").stdout.strip])
      File.read(File.join(clone, "upstream.txt")).should eq("newer upstream\n")
      File.read(File.join(clone, "local.txt")).should eq("local\n")
      GitOracle.run(clone, "status", "--porcelain").stdout.should eq("")
      GitOracle.run(clone, "fsck", "--strict", "--no-dangling")
    end
  end
end
