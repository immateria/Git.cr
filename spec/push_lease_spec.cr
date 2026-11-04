require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private SIG = Git::Signature.new("Lease Pusher", "lease@example.invalid", 1_700_000_000_i64, 0)

private def lease_at(time : Int64) : Hash(String, String)
  {"GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"}
end

private def lease_commit(root : String, message : String, time : Int64) : Nil
  GitOracle.run(root, "commit", "-q", "--allow-empty", "-m", message, extra_env: lease_at(time))
end

# The directories of one copy of the scenario.
private record LeaseCopy, bare : String, work : String, other : String do
  def oid(rev : String) : String
    GitOracle.run(bare, "rev-parse", rev).stdout.strip
  end
end

# A bare remote with main (c1 < c2) and side (c1 < s1), a tag v1 on c1, and
# two clones. The clone has local main and side equal to the remote's, with
# remote-tracking refs; `other` is a second clone used to move the remote.
# Everything is deterministic, so both copies get identical object IDs.
private def lease_copy(base : String, name : String) : LeaseCopy
  dir = File.join(base, name)
  bare = File.join(dir, "remote.git")
  seed = File.join(dir, "seed")
  Dir.mkdir_p(seed)
  GitOracle.run(dir, "init", "-q", "--bare", "--initial-branch=main", bare)
  GitOracle.run(dir, "clone", "-q", bare, seed)
  lease_commit(seed, "c1", 1_700_000_100)
  GitOracle.run(seed, "tag", "v1")
  lease_commit(seed, "c2", 1_700_000_200)
  GitOracle.run(seed, "switch", "-q", "-c", "side", "main~1")
  lease_commit(seed, "s1", 1_700_000_300)
  GitOracle.run(seed, "push", "-q", "origin", "main", "side", "v1")
  clone = File.join(dir, "clone")
  other = File.join(dir, "other")
  GitOracle.run(dir, "clone", "-q", bare, clone)
  GitOracle.run(clone, "branch", "side", "origin/side")
  GitOracle.run(dir, "clone", "-q", bare, other)
  LeaseCopy.new(bare, clone, other)
end

# Someone else adds a commit to a remote branch.
private def lease_move_remote(copy : LeaseCopy, branch : String, time : Int64) : Nil
  GitOracle.run(copy.other, "switch", "-q", "-C", branch, "origin/#{branch}")
  lease_commit(copy.other, "theirs on #{branch}", time)
  GitOracle.run(copy.other, "push", "-q", "origin", branch)
end

# Rewrites a local branch so that pushing it is not a fast-forward.
private def lease_rewrite(copy : LeaseCopy, branch : String, time : Int64) : Nil
  GitOracle.run(copy.work, "switch", "-q", branch)
  GitOracle.run(copy.work, "reset", "-q", "--hard", "#{branch}~1")
  lease_commit(copy.work, "rewritten #{branch}", time)
end

# The tracked state that must agree between Git and the library.
private def lease_state(copy : LeaseCopy) : String
  GitOracle.run(copy.bare, "for-each-ref", "--format=%(refname) %(objectname)").stdout +
    "--\n" +
    GitOracle.run(copy.work, "for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes").stdout
end

# Git's `--porcelain` lines as {remote ref, outcome}: "ok" or the reason.
private def porcelain_outcomes(output : String) : Array({String, String})
  outcomes = [] of {String, String}
  output.each_line do |line|
    flag = line[0]?
    next unless line.includes?('\t') && flag
    fields = line.split('\t')
    destination = fields[1].split(':', 2)[1]
    reason = fields[2]?.try { |summary| summary[/\(([^)]*)\)\s*$/, 1]? }
    outcomes << {destination, flag == '!' ? (reason || "rejected") : "ok"}
  end
  outcomes.sort_by(&.[0])
end

private def library_outcomes(result : Git::Push::Result) : Array({String, String})
  result.updates.map do |update|
    {update.remote_ref, update.success? ? "ok" : (update.reason || "rejected")}
  end.sort_by(&.[0])
end

# Builds two identical copies, prepares both, runs `git push` with the
# lease arguments on one and the library with the lease on the other, and
# compares the remote's refs, the remote-tracking refs and per-ref outcomes.
private def lease_matches_git(prepare : Proc(LeaseCopy, Nil), git_lease : Proc(LeaseCopy, Array(String)),
                              lease : Proc(LeaseCopy, Git::Push::Lease), refspecs : Array(String),
                              atomic : Bool = false, transport : Bool = false,
                              expect : Array({String, String})? = nil) : Nil
  base = File.tempname("push-lease", dir: File.realpath(Dir.tempdir))
  Dir.mkdir_p(base)
  begin
    by_git = lease_copy(base, "git")
    by_lib = lease_copy(base, "lib")
    prepare.call(by_git)
    prepare.call(by_lib)

    target = transport ? by_git.bare : "origin"
    args = ["push", "--porcelain"] + git_lease.call(by_git)
    args << "--atomic" if atomic
    args << target
    args.concat(refspecs)
    pushed = GitOracle.run_args(by_git.work, args, check: false)

    repo = Git::Repository.new(by_lib.work)
    result = if transport
               repo.push(Git::Transport.for_url(by_lib.bare), refspecs, lease: lease.call(by_lib), atomic: atomic)
             else
               repo.push("origin", refspecs, lease: lease.call(by_lib), atomic: atomic)
             end

    git_outcomes = porcelain_outcomes(pushed.stdout)
    library_outcomes(result).should eq(git_outcomes)
    result.success?.should eq(pushed.success?)
    lease_state(by_lib).should eq(lease_state(by_git))
    git_outcomes.should eq(expect) if expect
    GitOracle.run(by_lib.bare, "fsck", "--strict", "--no-dangling")
  ensure
    FileUtils.rm_rf(base)
  end
end

private def no_prepare : Proc(LeaseCopy, Nil)
  ->(copy : LeaseCopy) { nil }
end

private MAIN = "refs/heads/main"
private SIDE = "refs/heads/side"

describe "Git push --force-with-lease" do
  it "LEASE-O01 lets a bare lease force a non-fast-forward rewrite" do
    lease_matches_git(
      ->(copy : LeaseCopy) { lease_rewrite(copy, "main", 1_700_001_000_i64) },
      ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      ["main"], expect: [{MAIN, "ok"}])
  end

  it "LEASE-O02 rejects a bare lease as stale after someone else pushed" do
    prepare = ->(copy : LeaseCopy) do
      lease_move_remote(copy, "main", 1_700_001_100_i64)
      lease_rewrite(copy, "main", 1_700_001_000_i64)
    end
    lease_matches_git(prepare, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      ["main"], expect: [{MAIN, "stale info"}])
  end

  it "LEASE-O03 accepts an explicit ref:oid expectation that still holds" do
    lease_matches_git(
      ->(copy : LeaseCopy) { lease_rewrite(copy, "main", 1_700_001_000_i64) },
      ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("main")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"refs/heads/main" => copy.oid("main")}) },
      ["main"], expect: [{MAIN, "ok"}])
  end

  it "LEASE-O04 rejects an explicit expectation that is stale" do
    prepare = ->(copy : LeaseCopy) do
      lease_move_remote(copy, "main", 1_700_001_100_i64)
      lease_rewrite(copy, "main", 1_700_001_000_i64)
    end
    # The expectation is the value before the other push (the first commit).
    lease_matches_git(prepare,
      ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("v1")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"main" => copy.oid("v1")}) },
      ["main"], expect: [{MAIN, "stale info"}])
  end

  it "LEASE-O05 expands short ref names and treats an empty expectation as absent" do
    prepare = ->(copy : LeaseCopy) { GitOracle.run(copy.work, "branch", "fresh", "main") }
    # A new branch under `fresh:` is allowed.
    lease_matches_git(prepare, ->(copy : LeaseCopy) { ["--force-with-lease=fresh:"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"fresh" => nil}) },
      ["fresh"], expect: [{"refs/heads/fresh", "ok"}])
    # An existing branch under `side:` is stale, even if it would be forced.
    prepare_existing = ->(copy : LeaseCopy) { lease_rewrite(copy, "side", 1_700_001_000_i64) }
    lease_matches_git(prepare_existing, ->(copy : LeaseCopy) { ["--force-with-lease=side:"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"refs/heads/side" => nil}) },
      ["side"], expect: [{SIDE, "stale info"}])
  end

  it "LEASE-O06 matches Git for a lease on a ref without a remote-tracking ref" do
    # An existing remote ref expects absence: stale.
    drop = ->(copy : LeaseCopy) do
      lease_rewrite(copy, "side", 1_700_001_000_i64)
      GitOracle.run(copy.work, "update-ref", "-d", "refs/remotes/origin/side")
    end
    lease_matches_git(drop, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      ["side"], expect: [{SIDE, "stale info"}])
    # A ref the remote lacks needs no tracking ref.
    fresh = ->(copy : LeaseCopy) { GitOracle.run(copy.work, "branch", "brand-new", "main") }
    lease_matches_git(fresh, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      ["brand-new"], expect: [{"refs/heads/brand-new", "ok"}])
  end

  it "LEASE-O07 leaves refs outside the lease under the normal rules" do
    both = ->(copy : LeaseCopy) do
      lease_rewrite(copy, "main", 1_700_001_000_i64)
      lease_rewrite(copy, "side", 1_700_001_100_i64)
    end
    lease_matches_git(both, ->(copy : LeaseCopy) { ["--force-with-lease=main"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking(["main"]) },
      ["main", "side"], expect: [{MAIN, "ok"}, {SIDE, "non-fast-forward"}])
    lease_matches_git(both, ->(copy : LeaseCopy) { ["--force-with-lease=refs/heads/side"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking(["refs/heads/side"]) },
      ["main", "side"], expect: [{MAIN, "non-fast-forward"}, {SIDE, "ok"}])
    # An explicit expectation for one ref does not cover the other either.
    lease_matches_git(both,
      ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("main")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"main" => copy.oid("main")}) },
      ["main", "side"], expect: [{MAIN, "ok"}, {SIDE, "non-fast-forward"}])
  end

  it "LEASE-O08 fails the whole atomic push when one lease is stale" do
    prepare = ->(copy : LeaseCopy) do
      lease_move_remote(copy, "side", 1_700_001_100_i64)
      lease_rewrite(copy, "main", 1_700_001_000_i64)
      lease_rewrite(copy, "side", 1_700_001_200_i64)
    end
    lease_matches_git(prepare, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      ["main", "side"], atomic: true)
    # The stale side is the one that says so.
    base = File.tempname("push-lease", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(base)
    begin
      copy = lease_copy(base, "lib")
      prepare.call(copy)
      before = lease_state(copy)
      result = Git::Repository.new(copy.work).push("origin", ["main", "side"], atomic: true, lease: Git::Push::Lease.tracking)
      result.success?.should be_false
      result.updates.find! { |update| update.remote_ref == SIDE }.reason.should eq("stale info")
      lease_state(copy).should eq(before)
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "LEASE-O09 checks the lease when deleting a ref" do
    lease_matches_git(no_prepare, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      [":refs/heads/side"], expect: [{SIDE, "ok"}])
    stale = ->(copy : LeaseCopy) { lease_move_remote(copy, "side", 1_700_001_100_i64) }
    lease_matches_git(stale, ->(copy : LeaseCopy) { ["--force-with-lease"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.tracking },
      [":refs/heads/side"], expect: [{SIDE, "stale info"}])
    lease_matches_git(no_prepare, ->(copy : LeaseCopy) { ["--force-with-lease=side:#{copy.oid("main")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"side" => copy.oid("main")}) },
      [":side"], expect: [{SIDE, "stale info"}])
  end

  it "LEASE-O10 reports up to date before checking the lease, and a lease overrides tag protection" do
    lease_matches_git(no_prepare, ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("v1")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"main" => copy.oid("v1")}) },
      ["main"], expect: [{MAIN, "ok"}])
    moved_tag = ->(copy : LeaseCopy) { GitOracle.run(copy.work, "tag", "-f", "v1", "main") }
    lease_matches_git(moved_tag, ->(copy : LeaseCopy) { ["--force-with-lease=refs/tags/v1:#{copy.oid("v1")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"refs/tags/v1" => copy.oid("v1")}) },
      ["refs/tags/v1"], expect: [{"refs/tags/v1", "ok"}])
    lease_matches_git(moved_tag, ->(copy : LeaseCopy) { [] of String },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"refs/tags/other" => nil}) },
      ["refs/tags/v1"], expect: [{"refs/tags/v1", "already exists"}])
  end

  it "LEASE-O11 pushes to a transport with explicit expectations" do
    rewrite = ->(copy : LeaseCopy) { lease_rewrite(copy, "main", 1_700_001_000_i64) }
    lease_matches_git(rewrite, ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("main")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"main" => copy.oid("main")}) },
      ["main"], transport: true, expect: [{MAIN, "ok"}])
    stale = ->(copy : LeaseCopy) do
      lease_move_remote(copy, "main", 1_700_001_100_i64)
      lease_rewrite(copy, "main", 1_700_001_000_i64)
    end
    lease_matches_git(stale, ->(copy : LeaseCopy) { ["--force-with-lease=main:#{copy.oid("v1")}"] },
      ->(copy : LeaseCopy) { Git::Push::Lease.expect({"main" => copy.oid("v1")}) },
      ["main"], transport: true, expect: [{MAIN, "stale info"}])
  end

  it "LEASE-O12 refuses a tracking lease on a transport and malformed expectations" do
    base = File.tempname("push-lease", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(base)
    begin
      copy = lease_copy(base, "lib")
      repo = Git::Repository.new(copy.work)
      transport = Git::Transport.for_url(copy.bare)
      expect_raises(ArgumentError, /named remote/) do
        repo.push(transport, ["main"], lease: Git::Push::Lease.tracking)
      end
      expect_raises(ArgumentError, /named remote/) do
        repo.push(transport, ["main"], lease: Git::Push::Lease.tracking(["main"]))
      end
      expect_raises(Git::Error) do
        repo.push("origin", ["main"], lease: Git::Push::Lease.expect({"main" => "not-an-oid"}))
      end
      Git::Push::Lease.tracking.tracking?.should be_true
      Git::Push::Lease.expect({"main" => nil}).tracking?.should be_false
    ensure
      FileUtils.rm_rf(base)
    end
  end
end
