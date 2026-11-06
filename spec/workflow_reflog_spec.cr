require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# Each scenario runs Git on one copy of a fixture and the library on an
# identical copy, then compares HEAD, ORIG_HEAD, reflogs and branch
# configuration byte for byte. The library's actor is the identity and time
# the oracle's Git uses for the same commands.

private ACTOR_TIME = 1_700_000_900_i64
private ACTOR      = Git::Signature.new("Git Oracle", "oracle@example.invalid", ACTOR_TIME, 0)

private def at(time : Int64) : Hash(String, String)
  {"GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"}
end

private def git(root : String, *args : String, check : Bool = true) : GitOracle::Result
  GitOracle.run_args(root, args.to_a, check: check, extra_env: at(ACTOR_TIME))
end

private def commit_file(root : String, name : String, text : String, time : Int64) : Nil
  File.write(File.join(root, name), text)
  GitOracle.run(root, "add", name)
  GitOracle.run(root, "commit", "-qm", "#{name}: #{text.strip}", extra_env: at(time))
end

# main: a.txt, b.txt; topic (from main): t.txt.
private def history(root : String) : Nil
  commit_file(root, "a.txt", "one\n", 1_700_000_000)
  commit_file(root, "b.txt", "two\n", 1_700_000_100)
  GitOracle.run(root, "checkout", "-qb", "topic")
  commit_file(root, "t.txt", "topic\n", 1_700_000_200)
  GitOracle.run(root, "checkout", "-q", "main")
end

# Yield the Git copy and the native copy of a fixture.
private def twins(& : String, String ->) : Nil
  GitOracle.with_repo do |root|
    history(root)
    yield root, copy(root)
  end
end

private def copy(root : String) : String
  native = File.join(File.dirname(root), "native")
  status = Process.run("cp", ["-a", root, native])
  raise "copy failed" unless status.success?
  native
end

private def admin_file(root : String, name : String) : String?
  path = File.join(root, ".git", name)
  File.exists?(path) ? File.read(path) : nil
end

private def branch_config(root : String) : String
  GitOracle.run(root, "config", "--get-regexp", "^branch\\.", check: false).stdout
end

private def expect_same(git_root : String, native_root : String, *logs : String) : Nil
  {"HEAD", "ORIG_HEAD"}.each do |name|
    admin_file(native_root, name).should eq(admin_file(git_root, name))
  end
  logs.each do |log|
    admin_file(native_root, "logs/#{log}").should eq(admin_file(git_root, "logs/#{log}"))
  end
  branch_config(native_root).should eq(branch_config(git_root))
end

describe "Git reflogs and ORIG_HEAD for workflow commands" do
  it "RL-01 switch, switch -c and switch --detach log like Git" do
    twins do |git_root, native_root|
      git(git_root, "switch", "-q", "topic")
      git(git_root, "switch", "-q", "topic")
      git(git_root, "switch", "-q", "--detach", "HEAD~1")
      git(git_root, "switch", "-q", "main")
      git(git_root, "switch", "-q", "-c", "new", "topic")
      git(git_root, "switch", "-q", "-c", "same")
      repo = Git::Repository.new(native_root)
      repo.switch("topic", actor: ACTOR).reference.should eq("refs/heads/topic")
      repo.switch("topic", actor: ACTOR).changed_paths.should be_empty
      detached = repo.switch("HEAD~1", detach: true, actor: ACTOR)
      detached.reference.should be_nil
      detached.changed_paths.should eq(["t.txt"])
      repo.head.symref_target.should be_nil
      repo.switch("main", actor: ACTOR)
      created = repo.switch("new", create: true, from: "topic", actor: ACTOR)
      created.reference.should eq("refs/heads/new")
      created.changed_paths.should eq(["t.txt"])
      repo.switch("same", create: true, actor: ACTOR)
      expect_same(git_root, native_root, "HEAD", "refs/heads/new", "refs/heads/same")
    end
  end

  it "RL-02 switch -c from a remote-tracking branch and the remote guess track it like Git" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        GitOracle.run(root, "config", "remote.origin.url", "/nowhere")
        GitOracle.run(root, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        GitOracle.run(root, "update-ref", "refs/remotes/origin/main", "main")
        GitOracle.run(root, "update-ref", "refs/remotes/origin/feat", "topic")
      end
      git(git_root, "switch", "-q", "-c", "new", "origin/main")
      git(git_root, "switch", "-q", "feat")
      git(git_root, "switch", "-q", "-c", "local", "main")
      git(git_root, "switch", "-q", "-c", "untracked", "--no-track", "origin/main")
      repo = Git::Repository.new(native_root)
      repo.switch("new", create: true, from: "origin/main", actor: ACTOR)
      repo.switch("feat", actor: ACTOR).changed_paths.should eq(["t.txt"])
      repo.switch("local", create: true, from: "main", actor: ACTOR)
      repo.switch("untracked", create: true, from: "origin/main", track: false, actor: ACTOR)
      expect_same(git_root, native_root, "HEAD", "refs/heads/new", "refs/heads/feat", "refs/heads/local")
      repo.branches.list.find! { |branch| branch.name == "feat" }.upstream.should eq(Git::Branch::Upstream.new("origin", "refs/heads/feat"))
    end
  end

  it "RL-03 branch creation follows branch.autoSetupMerge like Git" do
    {"always", "false", "simple", "inherit"}.each do |mode|
      twins do |git_root, native_root|
        [git_root, native_root].each do |root|
          GitOracle.run(root, "config", "remote.origin.url", "/nowhere")
          GitOracle.run(root, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
          GitOracle.run(root, "update-ref", "refs/remotes/origin/main", "main")
          GitOracle.run(root, "config", "branch.main.remote", "origin")
          GitOracle.run(root, "config", "branch.main.merge", "refs/heads/main")
          GitOracle.run(root, "config", "branch.autoSetupMerge", mode)
        end
        git(git_root, "branch", "from-local", "main")
        git(git_root, "branch", "from-remote", "origin/main")
        git(git_root, "branch", "main2", "origin/main")
        repo = Git::Repository.new(native_root)
        repo.branches.create("from-local", from: "main", actor: ACTOR)
        repo.branches.create("from-remote", from: "origin/main", actor: ACTOR)
        repo.branches.create("main2", from: "origin/main", actor: ACTOR)
        expect_same(git_root, native_root, "refs/heads/from-local", "refs/heads/from-remote")
      end
    end
  end

  it "RL-04 switch refuses what Git refuses" do
    twins do |_git_root, native_root|
      repo = Git::Repository.new(native_root)
      expect_raises(Git::Error, /already exists/) { repo.switch("topic", create: true) }
      expect_raises(Git::Error, /branch missing/) { repo.switch("nope") }
      expect_raises(Git::Error, /branch missing/) { repo.switch("nope", guess: false) }
      expect_raises(ArgumentError, /create and detach/) { repo.switch("x", create: true, detach: true) }
      expect_raises(ArgumentError, /needs create/) { repo.switch("topic", from: "main") }
      repo.head.symref_target.should eq("refs/heads/main")
      File.exists?(File.join(native_root, ".git", "refs", "heads", "nope")).should be_false
    end
  end

  it "RL-05 the remote guess picks checkout.defaultRemote and refuses ambiguity" do
    twins do |_git_root, native_root|
      {"origin", "other"}.each do |name|
        GitOracle.run(native_root, "config", "remote.#{name}.url", "/nowhere")
        GitOracle.run(native_root, "config", "remote.#{name}.fetch", "+refs/heads/*:refs/remotes/#{name}/*")
        GitOracle.run(native_root, "update-ref", "refs/remotes/#{name}/feat", "topic")
      end
      repo = Git::Repository.new(native_root)
      expect_raises(Git::Error, /more than one remote-tracking branch/) { repo.switch("feat") }
      GitOracle.run(native_root, "config", "checkout.defaultRemote", "other")
      repo.switch("feat")
      repo.branches.upstream("feat").should eq(Git::Branch::Upstream.new("other", "refs/heads/feat"))
    end
  end

  it "RL-06 reset writes ORIG_HEAD and Git's reflog lines in every mode" do
    twins do |git_root, native_root|
      git(git_root, "reset", "-q", "--soft", "HEAD~1")
      git(git_root, "reset", "-q", "--mixed", "ORIG_HEAD")
      git(git_root, "reset", "-q")
      git(git_root, "reset", "-q", "--hard", "HEAD~1")
      git(git_root, "reset", "-q", "--soft")
      repo = Git::Repository.new(native_root)
      repo.reset("HEAD~1", mode: Git::Reset::Mode::Soft, actor: ACTOR)
      repo.reset("ORIG_HEAD", mode: Git::Reset::Mode::Mixed, actor: ACTOR)
      repo.reset(actor: ACTOR)
      repo.reset("HEAD~1", mode: Git::Reset::Mode::Hard, actor: ACTOR)
      repo.reset(mode: Git::Reset::Mode::Soft, actor: ACTOR)
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-07 fast-forwards log like `git merge` and `git merge --ff-only`" do
    twins do |git_root, native_root|
      git(git_root, "merge", "-q", "--ff-only", "topic")
      git(git_root, "reset", "-q", "--hard", "ORIG_HEAD")
      git(git_root, "merge", "-q", "topic")
      repo = Git::Repository.new(native_root)
      repo.fast_forward("topic", actor: ACTOR).changed_paths.should eq(["t.txt"])
      repo.reset("ORIG_HEAD", mode: Git::Reset::Mode::Hard, actor: ACTOR)
      result = repo.merge("topic", author: ACTOR, committer: ACTOR, message: "unused\n")
      result.commit_oid.should eq(repo.refs.resolve?("refs/heads/topic"))
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-08 a clean merge commit and an already-merged source log like Git" do
    twins do |git_root, native_root|
      [git_root, native_root].each { |root| commit_file(root, "c.txt", "main\n", 1_700_000_300) }
      git(git_root, "merge", "-q", "--no-edit", "topic")
      git(git_root, "merge", "-q", "topic")
      repo = Git::Repository.new(native_root)
      merged = repo.merge("topic", author: ACTOR, committer: ACTOR, message: "Merge branch 'topic'\n")
      merged.conflicts.should be_empty
      repo.merge("topic", author: ACTOR, committer: ACTOR, message: "unused\n").commit_oid.should be_nil
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-09 a conflicted merge sets ORIG_HEAD and its continuation logs commit (merge)" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        commit_file(root, "t.txt", "main side\n", 1_700_000_300)
      end
      git(git_root, "merge", "-q", "topic", check: false).success?.should be_false
      File.write(File.join(git_root, "t.txt"), "resolved\n")
      git(git_root, "add", "t.txt")
      git(git_root, "commit", "-q", "--no-edit")
      repo = Git::Repository.new(native_root)
      started = repo.merge("topic", author: ACTOR, committer: ACTOR, message: "Merge branch 'topic'\n")
      started.conflicts.should eq(["t.txt"])
      admin_file(native_root, "ORIG_HEAD").should eq(admin_file(git_root, "ORIG_HEAD"))
      repo.refs.resolve?("ORIG_HEAD").should eq(admin_file(git_root, "ORIG_HEAD").not_nil!.strip)
      repo.refs.resolve?("MERGE_HEAD").should eq(repo.refs.resolve?("refs/heads/topic"))
      File.write(File.join(native_root, "t.txt"), "resolved\n")
      repo.stage_file("t.txt")
      repo.merge.continue(author: ACTOR, committer: ACTOR)
      git_line = admin_file(git_root, "logs/HEAD").not_nil!.lines.last.split('\t', 2)[1]
      native_line = admin_file(native_root, "logs/HEAD").not_nil!.lines.last.split('\t', 2)[1]
      native_line.should eq(git_line)
      native_line.should eq("commit (merge): Merge branch 'topic'")
    end
  end

  it "RL-10 amend rewrites the commit and logs like `git commit --amend`" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        File.write(File.join(root, "b.txt"), "two, amended\n")
        GitOracle.run(root, "add", "b.txt")
      end
      git(git_root, "commit", "-q", "--amend", "--no-edit")
      git(git_root, "commit", "-q", "--amend", "-m", "reworded")
      git(git_root, "commit", "-q", "--amend", "--allow-empty", "--no-edit")
      repo = Git::Repository.new(native_root)
      first = repo.amend(committer: ACTOR)
      repo.read_commit(first).subject.should eq("b.txt: two")
      second = repo.amend(committer: ACTOR, message: "reworded\n")
      repo.read_commit(second).parents.should eq(repo.read_commit(first).parents)
      repo.amend(committer: ACTOR, allow_empty: true)
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-11 amend refuses a commit it would empty, as Git does" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        GitOracle.run(root, "rm", "-q", "--cached", "b.txt")
      end
      git(git_root, "commit", "-q", "--amend", "--no-edit", check: false).success?.should be_false
      repo = Git::Repository.new(native_root)
      expect_raises(Git::Error, /make the commit empty/) { repo.amend(committer: ACTOR) }
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
      repo.amend(committer: ACTOR, author: ACTOR, message: "empty\n", allow_empty: true)
      repo.read_commit(repo.refs.resolve?("HEAD").not_nil!).author.should eq(ACTOR.to_git_header)
    end
  end

  it "RL-12 amend keeps a merge commit's parents" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        commit_file(root, "c.txt", "main\n", 1_700_000_300)
        GitOracle.run(root, "merge", "-q", "--no-edit", "topic", extra_env: at(1_700_000_400))
      end
      git(git_root, "commit", "-q", "--amend", "-m", "merged")
      repo = Git::Repository.new(native_root)
      oid = repo.amend(committer: ACTOR, message: "merged\n")
      repo.read_commit(oid).parents.size.should eq(2)
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-13 rebase records the branch's previous commit in ORIG_HEAD" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        commit_file(root, "c.txt", "main\n", 1_700_000_300)
        GitOracle.run(root, "checkout", "-q", "topic")
      end
      git(git_root, "rebase", "-q", "main")
      repo = Git::Repository.new(native_root)
      repo.rebase("main", committer: ACTOR).completed.should be_true
      admin_file(native_root, "ORIG_HEAD").should eq(admin_file(git_root, "ORIG_HEAD"))
      repo.refs.resolve?("HEAD").should eq(GitOracle.run(git_root, "rev-parse", "HEAD").stdout.strip)
    end
  end

  it "RL-14 detached-HEAD commit, amend, reset, fast-forward and merge match Git" do
    twins do |git_root, native_root|
      git(git_root, "switch", "-q", "--detach", "HEAD")
      File.write(File.join(git_root, "d.txt"), "detached\n")
      git(git_root, "add", "d.txt")
      git(git_root, "commit", "-qm", "detached commit")
      File.write(File.join(git_root, "d.txt"), "detached amended\n")
      git(git_root, "add", "d.txt")
      git(git_root, "commit", "-q", "--amend", "-m", "detached amended")
      git(git_root, "reset", "-q", "--hard", "main")
      git(git_root, "merge", "-q", "--ff-only", "topic")
      git(git_root, "reset", "-q", "--hard", "main")
      File.write(File.join(git_root, "c.txt"), "main\n")
      git(git_root, "add", "c.txt")
      git(git_root, "commit", "-qm", "diverged")
      git(git_root, "merge", "-q", "--no-edit", "topic")

      repo = Git::Repository.new(native_root)
      repo.switch("HEAD", detach: true, actor: ACTOR)
      File.write(File.join(native_root, "d.txt"), "detached\n")
      repo.stage_file("d.txt")
      repo.commit(author: ACTOR, committer: ACTOR, message: "detached commit\n")
      File.write(File.join(native_root, "d.txt"), "detached amended\n")
      repo.stage_file("d.txt")
      repo.amend(committer: ACTOR, message: "detached amended\n")
      repo.reset("main", mode: Git::Reset::Mode::Hard, actor: ACTOR).reference.should be_nil
      repo.fast_forward("topic", actor: ACTOR)
      repo.reset("main", mode: Git::Reset::Mode::Hard, actor: ACTOR)
      File.write(File.join(native_root, "c.txt"), "main\n")
      repo.stage_file("c.txt")
      repo.commit(author: ACTOR, committer: ACTOR, message: "diverged\n")
      repo.merge("topic", author: ACTOR, committer: ACTOR, message: "Merge branch 'topic' into HEAD\n")
      expect_same(git_root, native_root, "HEAD", "refs/heads/main")
    end
  end

  it "RL-15 switch -C, switch - and branch -c log and copy config like Git" do
    twins do |git_root, native_root|
      [git_root, native_root].each do |root|
        GitOracle.run(root, "config", "branch.main.description", "main branch")
      end
      git(git_root, "branch", "-c", "main", "copied")
      git(git_root, "switch", "-q", "topic")
      git(git_root, "switch", "-q", "-")
      git(git_root, "switch", "-q", "-C", "copied", "topic")

      repo = Git::Repository.new(native_root)
      repo.branches.copy("main", "copied", actor: ACTOR)
      repo.switch("topic", actor: ACTOR)
      repo.switch("-", actor: ACTOR).reference.should eq("refs/heads/main")
      repo.switch("copied", force_create: true, from: "topic", actor: ACTOR)
      expect_same(git_root, native_root, "HEAD", "refs/heads/copied")
    end
  end
end
