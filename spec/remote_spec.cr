require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"
require "./support/git_http"

private SIG = Git::Signature.new("Native Fetcher", "fetcher@example.invalid", 1_700_000_000_i64, 0)

private def at(time : Int64) : Hash(String, String)
  {"GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"}
end

# A source repository with branches, annotated and lightweight tags, a
# nested tag, an executable, a symlink, a submodule entry and binary data.
private def remote_source(root : String) : Nil
  Dir.mkdir_p(File.join(root, "src", "deep"))
  File.write(File.join(root, "README.md"), "# remote\n")
  File.write(File.join(root, "src", "main.cr"), "puts :hi\n")
  File.write(File.join(root, "src", "deep", "data.bin"), String.new(Bytes.new(2048) { |i| (i * 7 % 256).to_u8 }))
  File.write(File.join(root, "run.sh"), "#!/bin/sh\necho run\n")
  File.chmod(File.join(root, "run.sh"), 0o755)
  File.symlink("src/main.cr", File.join(root, "link"))
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "commit", "-qm", "initial", extra_env: at(1_700_000_000))
  sub = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
  Dir.mkdir_p(File.join(root, "vendor", "sub"))
  GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{sub},vendor/sub")
  GitOracle.run(root, "commit", "-qm", "add submodule entry", extra_env: at(1_700_000_100))
  GitOracle.run(root, "tag", "light")
  4.times do |i|
    File.write(File.join(root, "src", "main.cr"), "puts #{i}\n" * (i + 2))
    GitOracle.run(root, "commit", "-qam", "main #{i}", extra_env: at(1_700_000_200 + i * 100))
  end
  GitOracle.run(root, "tag", "-a", "v1", "-m", "version 1\n", "HEAD~1", extra_env: at(1_700_001_000))
  GitOracle.run(root, "tag", "-a", "v1-outer", "-m", "nested\n", "v1", extra_env: at(1_700_001_000))
  GitOracle.run(root, "checkout", "-q", "-b", "feature", "HEAD~2")
  File.write(File.join(root, "feature.txt"), "feature\n")
  GitOracle.run(root, "add", "feature.txt")
  GitOracle.run(root, "commit", "-qm", "feature work", extra_env: at(1_700_002_000))
  GitOracle.run(root, "checkout", "-q", "main")
end

private def refs_of(root : String, prefix : String = "refs/") : String
  GitOracle.run(root, "for-each-ref", "--format=%(objectname) %(refname) %(symref)", prefix).stdout
end

private def compare_clones(native : String, oracle : String) : Nil
  refs_of(native).should eq(refs_of(oracle))
  GitOracle.run(native, "symbolic-ref", "HEAD").stdout.should eq(GitOracle.run(oracle, "symbolic-ref", "HEAD").stdout)
  GitOracle.run(native, "ls-files", "-s").stdout.should eq(GitOracle.run(oracle, "ls-files", "-s").stdout)
  ["remote.origin.fetch", "branch.main.remote", "branch.main.merge"].each do |key|
    GitOracle.run(native, "config", "--get-all", key).stdout.should eq(GitOracle.run(oracle, "config", "--get-all", key).stdout)
  end
  GitOracle.run(native, "fsck", "--strict", "--no-dangling")
  GitOracle.run(native, "status", "--porcelain").stdout.should eq("")
end

describe "Git remote operations" do
  ["sha1", "sha256"].each do |format|
    it "REMOTE-O01 clones over the local transport like git clone (#{format})" do
      GitOracle.with_repo(format: format) do |source|
        remote_source(source)
        base = File.dirname(source)
        native = File.join(base, "native")
        oracle = File.join(base, "oracle")
        repo = Git::Repository.clone(source, native, actor: SIG)
        GitOracle.run(base, "clone", "-q", "--no-local", source, oracle)
        compare_clones(native, oracle)
        repo.object_format.should eq(format == "sha256" ? Git::ObjectId::Format::SHA256 : Git::ObjectId::Format::SHA1)
        File.info(File.join(native, "run.sh")).permissions.owner_execute?.should be_true
        File.readlink(File.join(native, "link")).should eq("src/main.cr")
        Dir.exists?(File.join(native, "vendor", "sub")).should be_true
        File.read(File.join(native, "src", "deep", "data.bin")).should eq(File.read(File.join(source, "src", "deep", "data.bin")))
        repo.remote("origin").url.should eq(source)
        repo.branch_upstream("main").should eq({"origin", "refs/heads/main"})
      end
    end
  end

  it "REMOTE-O02 fetches incrementally with pruning, forced updates and tag following like git fetch" do
    GitOracle.with_repo do |source|
      remote_source(source)
      base = File.dirname(source)
      native = File.join(base, "native")
      oracle = File.join(base, "oracle")
      repo = Git::Repository.clone(source, native, actor: SIG)
      GitOracle.run(base, "clone", "-q", "--no-local", source, oracle)

      # Advance main, rewrite feature, delete nothing yet, add branches and tags.
      File.write(File.join(source, "later.txt"), "later\n")
      GitOracle.run(source, "add", "later.txt")
      GitOracle.run(source, "commit", "-qm", "later", extra_env: at(1_700_003_000))
      GitOracle.run(source, "tag", "-a", "v2", "-m", "v2\n", extra_env: at(1_700_003_100))
      GitOracle.run(source, "branch", "-f", "feature", "main~3")
      GitOracle.run(source, "branch", "topic", "main~1")
      GitOracle.run(source, "checkout", "-q", "--orphan", "lonely")
      File.write(File.join(source, "lonely.txt"), "alone\n")
      GitOracle.run(source, "add", "lonely.txt")
      GitOracle.run(source, "commit", "-qm", "lonely root", extra_env: at(1_700_003_200))
      GitOracle.run(source, "tag", "lonely-tag")
      GitOracle.run(source, "checkout", "-q", "main")

      result = repo.fetch(actor: SIG)
      GitOracle.run(oracle, "fetch", "-q")
      refs_of(native).should eq(refs_of(oracle))
      File.read(File.join(native, ".git", "FETCH_HEAD")).should eq(File.read(File.join(oracle, ".git", "FETCH_HEAD")))
      statuses = result.updates.to_h { |update| {update.local_ref, update.status} }
      statuses["refs/remotes/origin/main"].should eq(Git::Fetch::Update::Status::FastForward)
      statuses["refs/remotes/origin/feature"].should eq(Git::Fetch::Update::Status::Forced)
      statuses["refs/remotes/origin/topic"].should eq(Git::Fetch::Update::Status::New)
      statuses["refs/tags/v2"].should eq(Git::Fetch::Update::Status::New)
      result.object_count.should be > 0

      # A second fetch transfers nothing.
      again = repo.fetch
      again.pack.should be_nil
      again.updates.all? { |update| update.status.up_to_date? || update.status.fetch_head_only? }.should be_true

      # Pruning removes a branch deleted upstream; reflogs were written.
      GitOracle.run(source, "branch", "-D", "topic")
      pruned = repo.fetch(prune: true)
      GitOracle.run(oracle, "fetch", "-q", "--prune")
      refs_of(native).should eq(refs_of(oracle))
      pruned.updates.any? { |update| update.status.pruned? && update.local_ref == "refs/remotes/origin/topic" }.should be_true
      File.read(File.join(native, ".git", "logs", "refs", "remotes", "origin", "main")).should contain("fetch origin: fast-forward")

      # Git agrees the native repository is complete and clean.
      GitOracle.run(native, "fsck", "--strict", "--no-dangling")
    end
  end

  it "REMOTE-O03 serves git clone, fetch and push from the native HTTP server" do
    GitOracle.with_repo do |source|
      remote_source(source)
      base = File.dirname(source)
      served = File.join(base, "served.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, served)
      log = [] of GitHTTP::Request
      GitHTTP.native({"/served.git" => served}, log: log) do |url|
        clone = File.join(base, "git-client")
        GitOracle.run(base, "-c", "protocol.version=2", "clone", "-q", "#{url}/served.git", clone)
        GitOracle.run(clone, "fsck", "--strict", "--no-dangling")
        expected = refs_of(served, "refs/heads/").gsub(" refs/heads/", " refs/remotes/origin/")
        refs_of(clone, "refs/remotes/").lines(chomp: false).reject(&.includes?("origin/HEAD")).join.should eq(expected)
        GitOracle.run(clone, "rev-parse", "HEAD").stdout.should eq(GitOracle.run(served, "rev-parse", "main").stdout)
        GitOracle.run(clone, "tag", "-l").stdout.lines.sort.should eq(["light", "v1", "v1-outer"])
        log.any? { |entry| entry.path.ends_with?("git-upload-pack") && entry.git_protocol == "version=2" }.should be_true

        # Push new history, then an incremental fetch from a second clone.
        File.write(File.join(clone, "pushed.txt"), "pushed\n")
        GitOracle.run(clone, "add", "pushed.txt")
        GitOracle.run(clone, "commit", "-qm", "pushed", extra_env: at(1_700_005_000))
        GitOracle.run(clone, "push", "-q", "origin", "main", "main:refs/heads/created")
        GitOracle.run(served, "fsck", "--strict", "--no-dangling")
        GitOracle.run(served, "rev-parse", "main").stdout.should eq(GitOracle.run(clone, "rev-parse", "HEAD").stdout)
        GitOracle.run(served, "rev-parse", "created").stdout.should eq(GitOracle.run(clone, "rev-parse", "HEAD").stdout)
        second = File.join(base, "git-second")
        GitOracle.run(base, "clone", "-q", "#{url}/served.git", second)
        File.write(File.join(clone, "more.txt"), "more\n")
        GitOracle.run(clone, "add", "more.txt")
        GitOracle.run(clone, "commit", "-qm", "more", extra_env: at(1_700_005_100))
        GitOracle.run(clone, "push", "-q", "origin", "main")
        GitOracle.run(second, "fetch", "-q")
        GitOracle.run(second, "rev-parse", "origin/main").stdout.should eq(GitOracle.run(clone, "rev-parse", "HEAD").stdout)
        GitOracle.run(second, "fsck", "--strict", "--no-dangling")

        # Non-fast-forward pushes are refused by the client; deletes work.
        GitOracle.run(second, "reset", "-q", "--hard", "HEAD~2")
        File.write(File.join(second, "diverged.txt"), "diverged\n")
        GitOracle.run(second, "add", "diverged.txt")
        GitOracle.run(second, "commit", "-qm", "diverged", extra_env: at(1_700_005_200))
        GitOracle.run(second, "push", "-q", "origin", "main", check: false).success?.should be_false
        GitOracle.run(second, "push", "-q", "--force", "origin", "main")
        GitOracle.run(served, "rev-parse", "main").stdout.should eq(GitOracle.run(second, "rev-parse", "HEAD").stdout)
        GitOracle.run(clone, "push", "-q", "origin", ":created")
        GitOracle.run(served, "rev-parse", "--verify", "-q", "refs/heads/created", check: false).success?.should be_false

        # A shallow clone of depth 1.
        shallow = File.join(base, "git-shallow")
        GitOracle.run(base, "clone", "-q", "--depth=1", "#{url}/served.git", shallow)
        GitOracle.run(shallow, "rev-list", "--count", "HEAD").stdout.strip.should eq("1")
        GitOracle.run(shallow, "fsck", "--no-dangling")
      end
    end
  end

  ["sha1", "sha256"].each do |format|
    it "REMOTE-O04 clones, fetches and pushes over HTTP against git http-backend (#{format})" do
      GitOracle.with_repo(format: format) do |source|
        remote_source(source)
        base = File.dirname(source)
        project = File.join(base, "project")
        Dir.mkdir_p(project)
        served = File.join(project, "served.git")
        GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, served)
        GitOracle.run(served, "config", "http.receivepack", "true")
        log = [] of GitHTTP::Request
        GitHTTP.backend(project, log) do |url|
          native = File.join(base, "native")
          repo = Git::Repository.clone("#{url}/served.git", native, actor: SIG)
          oracle = File.join(base, "oracle")
          GitOracle.run(base, "clone", "-q", "--no-local", served, oracle)
          refs_of(native, "refs/tags/").should eq(refs_of(oracle, "refs/tags/"))
          refs_of(native, "refs/heads/").should eq(refs_of(oracle, "refs/heads/"))
          GitOracle.run(native, "fsck", "--strict", "--no-dangling")
          GitOracle.run(native, "status", "--porcelain").stdout.should eq("")
          log.any? { |entry| entry.git_protocol == "version=2" }.should be_true

          # Native push: new commit, new branch, new tag.
          repo = Git::Repository.new(native)
          File.write(File.join(native, "native.txt"), "from native\n")
          repo.stage_file("native.txt")
          commit = repo.commit_staged(author: SIG, committer: SIG, message: "native commit\n")
          repo.create_tag("native-tag", message: "tagged natively\n", tagger: SIG)
          pushed = repo.push("origin", ["main", "main:refs/heads/native-branch", "refs/tags/native-tag"], actor: SIG)
          pushed.success?.should be_true
          pushed.pack_objects.should be > 0
          GitOracle.run(served, "rev-parse", "main", "native-branch").stdout.lines.should eq([commit, commit])
          GitOracle.run(served, "cat-file", "-t", "native-tag").stdout.strip.should eq("tag")
          GitOracle.run(served, "fsck", "--strict", "--no-dangling")
          repo.resolve_ref?("refs/remotes/origin/main").should eq(commit)

          # The remote moves on; a non-fast-forward push is refused locally,
          # fetch picks the change up, and a forced push wins.
          GitOracle.run(oracle, "pull", "-q", "--ff-only")
          File.write(File.join(oracle, "upstream.txt"), "upstream\n")
          GitOracle.run(oracle, "add", "upstream.txt")
          GitOracle.run(oracle, "commit", "-qm", "upstream", extra_env: at(1_700_006_000))
          GitOracle.run(oracle, "push", "-q", "origin", "main")
          File.write(File.join(native, "native2.txt"), "again\n")
          repo.stage_file("native2.txt")
          local = repo.commit_staged(author: SIG, committer: SIG, message: "native again\n")
          refused = repo.push("origin")
          refused.success?.should be_false
          refused.rejected.first.reason.should eq("fetch first")
          fetched = repo.fetch(actor: SIG)
          fetched.updates.find { |update| update.local_ref == "refs/remotes/origin/main" }.not_nil!.status.should eq(Git::Fetch::Update::Status::FastForward)
          repo.push("origin").rejected.first.reason.should eq("non-fast-forward")
          repo.push("origin", force: true).success?.should be_true
          GitOracle.run(served, "rev-parse", "main").stdout.strip.should eq(local)

          # Delete over HTTP.
          repo.push("origin", [":native-branch"]).updates.first.status.should eq(Git::Push::Update::Status::Deleted)
          GitOracle.run(served, "rev-parse", "--verify", "-q", "refs/heads/native-branch", check: false).success?.should be_false
          repo.resolve_ref?("refs/remotes/origin/native-branch").should be_nil

          # Shallow native clone.
          shallow = File.join(base, "shallow")
          shallow_repo = Git::Repository.clone("#{url}/served.git", shallow, depth: 1)
          GitOracle.run(shallow, "rev-list", "--count", "HEAD").stdout.strip.should eq("1")
          GitOracle.run(shallow, "fsck", "--no-dangling")
          shallow_repo.shallow?.should be_true
        end
      end
    end
  end

  it "REMOTE-O05 pushes over the local transport with Git's update rules" do
    GitOracle.with_repo do |source|
      remote_source(source)
      base = File.dirname(source)
      bare = File.join(base, "bare.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, bare)
      native = File.join(base, "native")
      repo = Git::Repository.clone(bare, native)
      File.write(File.join(native, "a.txt"), "a\n")
      repo.stage_file("a.txt")
      first = repo.commit_staged(author: SIG, committer: SIG, message: "a\n")
      result = repo.push
      result.success?.should be_true
      GitOracle.run(bare, "rev-parse", "main").stdout.strip.should eq(first)
      repo.push.updates.first.status.should eq(Git::Push::Update::Status::UpToDate)

      # Tags are not moved without force.
      repo.create_tag("moving")
      repo.push("origin", ["refs/tags/moving"]).success?.should be_true
      File.write(File.join(native, "b.txt"), "b\n")
      repo.stage_file("b.txt")
      second = repo.commit_staged(author: SIG, committer: SIG, message: "b\n")
      repo.update_ref("refs/tags/moving", second, expected_oid: first)
      repo.push("origin", ["refs/tags/moving"]).rejected.first.reason.should eq("already exists")
      repo.push("origin", ["+refs/tags/moving"]).success?.should be_true
      GitOracle.run(bare, "rev-parse", "moving").stdout.strip.should eq(second)

      # Atomic pushes fail as a whole.
      repo.push("origin", ["main"]).success?.should be_true
      repo.update_ref("refs/heads/main", first, expected_oid: second)
      atomic = repo.push("origin", ["main", "main:refs/heads/fresh"], atomic: true)
      atomic.success?.should be_false
      GitOracle.run(bare, "rev-parse", "--verify", "-q", "refs/heads/fresh", check: false).success?.should be_false

      # The server refuses to update a checked-out branch of a worktree.
      worktree_clone = File.join(base, "worktree-clone")
      other = Git::Repository.clone(native, worktree_clone)
      File.write(File.join(worktree_clone, "c.txt"), "c\n")
      other.stage_file("c.txt")
      other.commit_staged(author: SIG, committer: SIG, message: "c\n")
      denied = other.push("origin", ["main"])
      denied.updates.first.status.should eq(Git::Push::Update::Status::RemoteRejected)
      denied.updates.first.reason.should eq("branch is currently checked out")
      GitOracle.run(bare, "fsck", "--strict", "--no-dangling")
    end
  end

  it "REMOTE-O06 manages remotes in the config like git remote" do
    GitOracle.with_repo do |root|
      remote_source(root)
      repo = Git::Repository.new(root)
      repo.add_remote("upstream", "https://example.invalid/upstream.git")
      repo.add_remote("mirror", "/srv/mirror.git", fetch: ["+refs/*:refs/mirror/*"], tag_mode: Git::Remote::TagMode::None)
      GitOracle.run(root, "remote", "-v").stdout.lines.sort.should eq([
        "mirror\t/srv/mirror.git (fetch)", "mirror\t/srv/mirror.git (push)",
        "upstream\thttps://example.invalid/upstream.git (fetch)", "upstream\thttps://example.invalid/upstream.git (push)",
      ])
      GitOracle.run(root, "config", "remote.mirror.tagOpt").stdout.strip.should eq("--no-tags")
      repo.remote_names.should eq(["upstream", "mirror"])
      repo.remote("upstream").fetch_refspecs.map(&.to_s).should eq(["+refs/heads/*:refs/remotes/upstream/*"])
      head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      repo.update_ref("refs/remotes/upstream/main", head, expected_oid: nil)
      repo.set_symbolic_ref("refs/remotes/upstream/HEAD", "refs/remotes/upstream/main")
      repo.set_branch_upstream("main", "upstream", "refs/heads/main")
      repo.rename_remote("upstream", "origin")
      GitOracle.run(root, "config", "--get", "remote.origin.fetch").stdout.strip.should eq("+refs/heads/*:refs/remotes/origin/*")
      GitOracle.run(root, "config", "--get", "branch.main.remote").stdout.strip.should eq("origin")
      GitOracle.run(root, "rev-parse", "refs/remotes/origin/main").stdout.strip.should eq(head)
      GitOracle.run(root, "symbolic-ref", "refs/remotes/origin/HEAD").stdout.strip.should eq("refs/remotes/origin/main")
      repo.remove_remote("origin")
      GitOracle.run(root, "config", "--get", "branch.main.remote", check: false).success?.should be_false
      refs_of(root, "refs/remotes/").should eq("")
      GitOracle.run(root, "remote").stdout.should eq("mirror\n")
      expect_raises(Git::Error, /invalid Git remote name/) { repo.add_remote("bad name", "x") }
      expect_raises(Git::Error, /already exists/) { repo.add_remote("mirror", "x") }
    end
  end

  it "REMOTE-O07 parses and maps refspecs like Git" do
    spec = Git::Remote::Refspec.parse("+refs/heads/*:refs/remotes/origin/*")
    spec.force?.should be_true
    spec.pattern?.should be_true
    spec.map_source("refs/heads/feature/x").should eq("refs/remotes/origin/feature/x")
    spec.map_source("refs/tags/v1").should be_nil
    spec.map_destination("refs/remotes/origin/main").should eq("refs/heads/main")
    Git::Remote::Refspec.parse("refs/heads/main:refs/heads/main").map_source("refs/heads/main").should eq("refs/heads/main")
    Git::Remote::Refspec.parse("refs/heads/*/suffix:refs/x/*").map_source("refs/heads/a/b/suffix").should eq("refs/x/a/b")
    Git::Remote::Refspec.parse("^refs/heads/secret").negative?.should be_true
    Git::Remote::Refspec.parse(":refs/heads/gone", fetch: false).source.should eq("")
    Git::RefName.expand("main", ["refs/tags/main", "refs/heads/main"]).should eq("refs/tags/main")
    ["refs/heads/*:refs/remotes/*/x/*", "refs/heads/*:refs/remotes/main", "refs/heads/a..b:x", "^a:b"].each do |bad|
      expect_raises(Git::Error) { Git::Remote::Refspec.parse(bad) }
    end
  end
end

describe "Git clone failure" do
  it "REMOTE-O08 removes what a failed clone created" do
    base = File.tempname("git-clone-failure", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(base)
    begin
      fresh = File.join(base, "fresh")
      expect_raises(Git::Error) { Git::Repository.clone(File.join(base, "missing"), fresh) }
      File.exists?(fresh).should be_false
      given = File.join(base, "given")
      Dir.mkdir(given)
      expect_raises(Git::Error) { Git::Repository.clone(File.join(base, "missing"), given) }
      Dir.exists?(given).should be_true
      Dir.empty?(given).should be_true
      File.write(File.join(given, "keep.txt"), "mine")
      expect_raises(Git::Error, /not an empty directory/) { Git::Repository.clone(File.join(base, "missing"), given) }
      File.read(File.join(given, "keep.txt")).should eq("mine")
    ensure
      FileUtils.rm_rf(base)
    end
  end
end
