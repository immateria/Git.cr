# Differential checks and timings of the library against Git on a real
# repository (a normal clone made by Git). Every check runs the native
# operation and Git's equivalent, compares the answers and reports both
# times. The repository's worktree is modified and then restored by the
# status checks; its refs and objects are not changed.
#
#   crystal build --release bench/realworld.cr -o bin/realworld
#   GIT_ORACLE_BINARY=/usr/local/bin/git bin/realworld /path/to/clone [options]
#
# This is a development tool: it runs the `git` program. The library never does.

require "option_parser"
require "file_utils"
require "json"
require "../src/git"

module RealWorld
  GIT        = ENV["GIT_ORACLE_BINARY"]? || "git"
  EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  record Outcome, name : String, passed : Bool, items : Int64, native : Time::Span?,
    git : Time::Span?, detail : String

  class Failure < Exception
  end

  class Runner
    getter outcomes = [] of Outcome
    @repo : Git::Repository

    def initialize(@root : String, @sample : Int32, @seed : Int32, @scratch : String,
                   @remote_url : String?)
      @root = File.realpath(@root)
      @repo = open_repo
      @random = Random.new(@seed)
    end

    def open_repo : Git::Repository
      Git::Repository.new(@root, max_search_entries: 10_000_000, max_scan_bytes: 268_435_456)
    end

    # Run Git in the repository with no user or system configuration.
    def git(args : Array(String), *, dir : String = @root, check : Bool = true,
            input : String? = nil) : String
      env = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
             "LC_ALL" => "C", "TZ" => "UTC", "GIT_TERMINAL_PROMPT" => "0",
             "HOME" => @scratch}
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(GIT, ["-C", dir] + args, env: env, output: output, error: error,
        input: input ? IO::Memory.new(input) : Process::Redirect::Close)
      raise Failure.new("git #{args.first(4).join(' ')} failed: #{error.to_s.lines.first?}") if check && !status.success?
      output.to_s
    end

    # Run Git for its time only, discarding its output.
    def git_discard(args : Array(String)) : Nil
      env = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "LC_ALL" => "C"}
      File.open("/dev/null", "w") do |sink|
        status = Process.run(GIT, ["-C", @root] + args, env: env, output: sink, error: Process::Redirect::Close)
        raise Failure.new("git #{args.first(3).join(' ')} failed") unless status.success?
      end
    end

    def git_ok?(args : Array(String)) : Bool
      env = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "LC_ALL" => "C"}
      Process.run(GIT, ["-C", @root] + args, env: env, output: Process::Redirect::Close,
        error: Process::Redirect::Close).success?
    end

    def timed(&)
      started = Time.monotonic
      value = yield
      {value, Time.monotonic - started}
    end

    def run(name : String, &block : -> Outcome) : Nil
      STDERR.puts "-- #{name}"
      outcome = begin
        block.call
      rescue ex
        Outcome.new(name, false, 0, nil, nil, "#{ex.class}: #{ex.message}")
      end
      @outcomes << outcome
      STDERR.puts "   #{outcome.passed ? "ok" : "FAIL"} #{outcome.detail}"
    end

    # The first difference between two line lists, for a failure message.
    def first_difference(expected : Array(String), actual : Array(String)) : String
      index = (0...{expected.size, actual.size}.max).find { |i| expected[i]? != actual[i]? } || 0
      "line #{index + 1}: git #{expected[index]?.inspect} native #{actual[index]?.inspect} (#{expected.size} vs #{actual.size} lines)"
    end

    def sample_of(list : Array(T), count : Int32) : Array(T) forall T
      list.size <= count ? list : list.sample(count, @random)
    end

    def commits : Array(String)
      @commits ||= git(["rev-list", "--first-parent", "HEAD"]).split
    end

    @commits : Array(String)?

    # --- objects -----------------------------------------------------------

    def objects : Nil
      run("object headers (cat-file --batch-check)") do
        listing, git_time = timed { git(["cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)"]) }
        rows = listing.lines
        mismatches = [] of String
        _, native_time = timed do
          rows.each do |row|
            oid, type, size = row.split(' ')
            header = @repo.object_header(oid)
            mismatches << "#{oid}: #{header.type} #{header.size} vs #{type} #{size}" unless header.type.to_s == type && header.size == size.to_i64
          end
        end
        Outcome.new("object headers", mismatches.empty?, rows.size.to_i64, native_time, git_time,
          mismatches.empty? ? "#{rows.size} objects" : "#{mismatches.size} differ, first #{mismatches.first}")
      end
      run("object contents (cat-file --batch, hash-verified)") do
        oids = git(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"]).split
        _, git_time = timed { git_discard(["cat-file", "--batch-all-objects", "--batch"]) }
        bad = [] of String
        bytes = 0_i64
        _, native_time = timed do
          oids.each do |oid|
            object = @repo.read_object(oid, max_bytes: 268_435_456)
            bytes += object.data.bytesize
            digest = Git::ObjectId.digest(object.type.to_s, object.data, @repo.object_format)
            bad << oid unless digest == oid
          end
        end
        Outcome.new("object contents", bad.empty?, oids.size.to_i64, native_time, git_time,
          bad.empty? ? "#{oids.size} objects, #{bytes // 1_048_576} MiB" : "#{bad.size} hash mismatches, first #{bad.first}")
      end
    end

    # --- history -----------------------------------------------------------

    def history : Nil
      run("rev-list HEAD") do
        expected, git_time = timed { git(["rev-list", "HEAD"]).split }
        actual, native_time = timed { @repo.rev_list(["HEAD"]) }
        same = expected == actual
        detail = if same
                   "#{actual.size} commits"
                 elsif expected.sort == actual.sort
                   "same #{actual.size} commits, different order: #{first_difference(expected, actual)}"
                 else
                   first_difference(expected, actual)
                 end
        Outcome.new("rev-list HEAD", same, actual.size.to_i64, native_time, git_time, detail)
      end
      {Git::History::Order::Default => nil, Git::History::Order::Date => "--date-order",
       Git::History::Order::Topological => "--topo-order"}.each do |order, flag|
        run("log order #{order} (rev-list #{flag})") do
          expected, git_time = timed { git(["rev-list", flag, "HEAD"].compact).split }
          result, native_time = timed do
            @repo.log(["HEAD"], limit: Int32::MAX, order: order, max_commits: 10_000_000)
          end
          actual = result.commits.map(&.oid)
          ok = expected == actual
          Outcome.new("log #{flag || "(default)"}", ok, actual.size.to_i64, native_time, git_time,
            ok ? "#{actual.size} commits" : first_difference(expected, actual))
        end
      end
      run("rev-parse expressions") do
        expressions = ["HEAD", "HEAD~1", "HEAD^{tree}", "HEAD~#{{commits.size - 1, 100}.min}", "@", "HEAD@{0}"]
        refs = git(["for-each-ref", "--format=%(refname)"]).lines
        refs.each { |ref| expressions << ref << ref.sub(/\Arefs\/(heads|tags|remotes)\//, "") }
        tags = refs.select(&.starts_with?("refs/tags/"))
        sample_of(tags, 20).each { |tag| expressions << "#{tag}^{}" << "#{tag}^{commit}" << "#{tag.byte_slice(10)}~2" }
        sample_of(commits, @sample).each do |oid|
          expressions << oid << oid[0, 7] << oid[0, 12] << "#{oid}^" << "#{oid}^{tree}"
        end
        files = git(["ls-tree", "-r", "--name-only", "HEAD"]).lines
        sample_of(files, 20).each { |path| expressions << "HEAD:#{path}" << ":#{path}" }
        expressions << "nonexistent-ref" << "HEAD~999999999"
        mismatches = [] of String
        git_time = Time::Span.zero
        native_time = Time::Span.zero
        expressions.uniq.each do |expression|
          expected, spent = timed do
            out = git(["rev-parse", "--verify", "-q", expression], check: false).strip
            out.empty? ? nil : out
          end
          git_time += spent
          actual, spent = timed do
            begin
              @repo.rev_parse(expression)
            rescue Git::Error
              nil
            end
          end
          native_time += spent
          mismatches << "#{expression}: git #{expected.inspect} native #{actual.inspect}" unless expected == actual
        end
        Outcome.new("rev-parse", mismatches.empty?, expressions.uniq.size.to_i64, native_time, git_time,
          mismatches.empty? ? "#{expressions.uniq.size} expressions" : "#{mismatches.size} differ: #{mismatches.first(3).join("; ")}")
      end
      run("merge-base --all (random pairs)") do
        all = git(["rev-list", "HEAD"]).split
        pairs = Array.new(@sample) { {all.sample(@random), all.sample(@random)} }
        mismatches = [] of String
        git_time = Time::Span.zero
        native_time = Time::Span.zero
        pairs.each do |left, right|
          expected, spent = timed { git(["merge-base", "--all", left, right], check: false).split.sort }
          git_time += spent
          actual, spent = timed { @repo.merge_bases(left, right, max_nodes: 10_000_000).sort }
          native_time += spent
          mismatches << "#{left[0, 10]} #{right[0, 10]}: #{expected} vs #{actual}" unless expected == actual
        end
        Outcome.new("merge-base", mismatches.empty?, pairs.size.to_i64, native_time, git_time,
          mismatches.empty? ? "#{pairs.size} pairs" : "#{mismatches.size} differ: #{mismatches.first}")
      end
    end

    # --- diffs -------------------------------------------------------------

    # Commits to diff: the newest first-parent commits and a random sample.
    def diff_commits : Array(String)
      (commits.first(@sample) + sample_of(commits, @sample)).uniq
    end

    def parent_of(oid : String) : String?
      git(["rev-parse", "--verify", "-q", "#{oid}^"], check: false).strip.presence
    end

    def diffs : Nil
      run("diff-tree --name-status") do
        mismatches = [] of String
        git_time = Time::Span.zero
        native_time = Time::Span.zero
        list = diff_commits
        list.each do |oid|
          parent = parent_of(oid)
          expected, spent = timed do
            args = ["diff-tree", "-r", "--name-status", "--no-commit-id"]
            git(parent ? args + [parent, oid] : args + ["--root", oid]).lines
          end
          git_time += spent
          actual, spent = timed { @repo.diff_trees(parent, oid).map(&.name_status) }
          native_time += spent
          mismatches << "#{oid[0, 10]}: #{first_difference(expected, actual)}" unless expected == actual
        end
        Outcome.new("diff-tree", mismatches.empty?, list.size.to_i64, native_time, git_time,
          mismatches.empty? ? "#{list.size} commits" : "#{mismatches.size}/#{list.size} differ: #{mismatches.first}")
      end
      [false, true].each do |attributes|
        label = attributes ? "with .gitattributes" : "no attributes"
        run("commit patches (#{label})") do
          mismatches = [] of String
          git_time = Time::Span.zero
          native_time = Time::Span.zero
          lines = 0_i64
          list = diff_commits
          list.each do |oid|
            parent = parent_of(oid) || EMPTY_TREE
            args = ["diff", "--no-color", "--no-ext-diff", "--abbrev=12", "-M100%", parent, oid]
            args = ["--attr-source=#{EMPTY_TREE}"] + args unless attributes
            expected, spent = timed { git(args) }
            git_time += spent
            actual, spent = timed do
              @repo.commit_patch(oid, abbrev: 12, attributes: attributes, max_bytes: 268_435_456, max_lines: 50_000_000).to_s
            end
            native_time += spent
            lines += expected.count('\n')
            mismatches << "#{oid[0, 10]}: #{first_difference(expected.lines, actual.lines)}" unless expected == actual
          end
          Outcome.new("patches #{label}", mismatches.empty?, list.size.to_i64, native_time, git_time,
            mismatches.empty? ? "#{list.size} commits, #{lines} patch lines" : "#{mismatches.size}/#{list.size} differ: #{mismatches.first(2).join(" | ")}")
        end
      end
    end

    # --- worktree ------------------------------------------------------------

    STATUS_CODES = {"modified" => " M", "deleted" => " D", "untracked" => "??", "typechanged" => " T"}

    def native_status : Array(String)
      changes = @repo.working_changes(limit: 10_000_000, max_bytes: 268_435_456)
      raise Failure.new("native status truncated") if changes.truncated?
      changes.map { |change| "#{STATUS_CODES[change.status]? || change.status} #{change.path}" }.sort
    end

    def git_status : Array(String)
      git(["status", "--porcelain=v1", "-uall", "--no-renames"]).lines.sort
    end

    def worktree : Nil
      dirty = git_status
      raise Failure.new("worktree is not clean: #{dirty.first}") unless dirty.empty?
      run("status on a clean checkout") do
        expected, git_time = timed { git_status }
        actual, native_time = timed { native_status }
        staged, staged_time = timed { @repo.staged_changes(limit: 10_000_000, max_bytes: 268_435_456).to_a }
        ok = expected == actual && staged.empty?
        Outcome.new("clean status", ok, git(["ls-files"]).lines.size.to_i64, native_time + staged_time, git_time,
          ok ? "worktree and index clean" : "#{actual.first(3)} staged #{staged.first(3).map(&.path)}")
      end
      edited = mutate_worktree
      begin
        run("status after #{edited} edits") do
          expected, git_time = timed { git_status }
          actual, native_time = timed { native_status }
          ok = expected == actual
          Outcome.new("dirty status", ok, expected.size.to_i64, native_time, git_time,
            ok ? "#{expected.size} entries" : first_difference(expected, actual))
        end
        run("git diff of the edits") do
          expected, git_time = timed { git(["diff", "--no-color", "--abbrev=12"]) }
          actual, native_time = timed { @repo.diff(abbrev: 12, max_bytes: 268_435_456, max_lines: 50_000_000).to_s }
          ok = expected == actual
          Outcome.new("worktree diff", ok, expected.count('\n').to_i64, native_time, git_time,
            ok ? "#{expected.count('\n')} lines" : first_difference(expected.lines, actual.lines))
        end
        run("stage (git add -A)") do
          _, native_time = timed { @repo.stage(max_paths: 10_000_000, max_bytes: 268_435_456, max_index_bytes: 268_435_456) }
          native_index = git(["ls-files", "-s"])
          native_patch = @repo.diff(cached: true, abbrev: 12, max_bytes: 268_435_456, max_lines: 50_000_000).to_s
          git(["reset", "-q"])
          _, git_time = timed { git(["add", "-A"]) }
          git_index = git(["ls-files", "-s"])
          git_patch = git(["diff", "--cached", "--no-color", "--abbrev=12"])
          ok = native_index == git_index && native_patch == git_patch
          detail = if native_index != git_index
                     "index: #{first_difference(git_index.lines, native_index.lines)}"
                   elsif native_patch != git_patch
                     "diff --cached: #{first_difference(git_patch.lines, native_patch.lines)}"
                   else
                     "#{git_index.lines.size} index entries, diff --cached equal"
                   end
          Outcome.new("stage", ok, git_index.lines.size.to_i64, native_time, git_time, detail)
        end
      ensure
        git(["reset", "-q", "--hard"])
        git(["clean", "-fdq"])
        @repo = open_repo
      end
    end

    # Deterministic edits: modify, delete, chmod and add files. Returns how many.
    def mutate_worktree : Int32
      files = git(["ls-files", "-s"]).lines.compact_map do |line|
        meta, path = line.split('\t', 2)
        meta.starts_with?("100644") ? path : nil
      end
      pick = sample_of(files, 40)
      pick[0, 20].each { |path| File.open(File.join(@root, path), "a") { |io| io << "\nrealworld edit\n" } }
      pick[20, 5].each { |path| File.delete(File.join(@root, path)) }
      pick[25, 5].each do |path|
        full = File.join(@root, path)
        lines = File.read(full).lines
        File.write(full, lines.reverse.join) unless lines.empty?
      end
      pick[30, 2].each { |path| File.chmod(File.join(@root, path), 0o755) }
      Dir.mkdir_p(File.join(@root, "realworld-new", "nested"))
      File.write(File.join(@root, "realworld-new", "nested", "added.txt"), "new file\n")
      File.write(File.join(@root, "realworld-added.md"), "# added\n")
      pick.size + 2
    end

    # --- transfer ------------------------------------------------------------

    def clone_local : Nil
      run("clone over the local transport") do
        native_dir = File.join(@scratch, "native-clone")
        git_dir = File.join(@scratch, "git-clone")
        FileUtils.rm_rf(native_dir)
        FileUtils.rm_rf(git_dir)
        _, native_time = timed { Git::Repository.clone(@root, native_dir) }
        _, git_time = timed { git(["clone", "-q", "--no-local", @root, git_dir], dir: @scratch) }
        problems = [] of String
        native_refs = git(["for-each-ref", "--format=%(objectname) %(refname)"], dir: native_dir)
        git_refs = git(["for-each-ref", "--format=%(objectname) %(refname)"], dir: git_dir)
        problems << "refs: #{first_difference(git_refs.lines, native_refs.lines)}" unless native_refs == git_refs
        native_index = git(["ls-files", "-s"], dir: native_dir)
        problems << "index differs" unless native_index == git(["ls-files", "-s"], dir: git_dir)
        status = git(["status", "--porcelain"], dir: native_dir)
        problems << "status not clean: #{status.lines.first}" unless status.empty?
        fsck = Process.run(GIT, ["-C", native_dir, "fsck", "--strict", "--no-progress"],
          env: {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null"},
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        problems << "git fsck --strict fails" unless fsck.success?
        objects = git(["count-objects", "-v"], dir: native_dir)[/in-pack: (\d+)/, 1].to_i64
        FileUtils.rm_rf(native_dir)
        FileUtils.rm_rf(git_dir)
        Outcome.new("clone (local)", problems.empty?, objects, native_time, git_time,
          problems.empty? ? "#{objects} objects; refs, index, status and fsck --strict agree" : problems.join("; "))
      end
    end

    def clone_https : Nil
      url = @remote_url || return
      run("clone over HTTPS (#{url})") do
        native_dir = File.join(@scratch, "native-https")
        git_dir = File.join(@scratch, "git-https")
        FileUtils.rm_rf(native_dir)
        FileUtils.rm_rf(git_dir)
        tls = OpenSSL::SSL::Context::Client.new
        if bundle = ENV["SSL_CERT_FILE"]?.presence || (File.exists?("/root/.ccr/ca-bundle.crt") ? "/root/.ccr/ca-bundle.crt" : nil)
          tls.ca_certificates = bundle
        end
        proxy = ENV["HTTPS_PROXY"]? || ENV["https_proxy"]?
        transport = Git::Transport::HTTP.new(url, tls: tls, proxy: proxy)
        _, native_time = timed { Git::Repository.clone(transport, native_dir, url: url) }
        _, git_time = timed { git(["clone", "-q", url, git_dir], dir: @scratch) }
        native_refs = git(["for-each-ref", "--format=%(objectname) %(refname)"], dir: native_dir)
        git_refs = git(["for-each-ref", "--format=%(objectname) %(refname)"], dir: git_dir)
        clean = git(["status", "--porcelain"], dir: native_dir).empty?
        ok = native_refs == git_refs && clean
        FileUtils.rm_rf(native_dir)
        FileUtils.rm_rf(git_dir)
        Outcome.new("clone (https)", ok, native_refs.lines.size.to_i64, native_time, git_time,
          ok ? "#{native_refs.lines.size} refs agree, clean checkout" : (clean ? "refs: #{first_difference(git_refs.lines, native_refs.lines)}" : "checkout not clean"))
      end
    end

    def index_pack : Nil
      run("index-pack of the clone's pack") do
        pack = Dir.glob(File.join(@root, ".git", "objects", "pack", "*.pack")).max_by { |path| File.size(path) }
        target = File.join(@scratch, "index-pack.git")
        FileUtils.rm_rf(target)
        Dir.mkdir_p(target)
        repo = Git::Repository.init(target, bare: true, object_format: @repo.object_format)
        published, native_time = timed do
          File.open(pack) { |io| repo.index_pack(io, fix_thin: false, check_collisions: false) }
        end
        git_target = File.join(@scratch, "index-pack-git.pack")
        FileUtils.cp(pack, git_target)
        _, git_time = timed { git(["index-pack", "-o", git_target.sub(/\.pack\z/, ".idx"), "--rev-index", git_target], dir: @scratch) }
        native_idx = File.read(published.index_path.not_nil!)
        git_idx = File.read(git_target.sub(/\.pack\z/, ".idx"))
        native_rev = File.read(published.index_path.not_nil!.sub(/\.idx\z/, ".rev"))
        git_rev = File.read(git_target.sub(/\.pack\z/, ".rev"))
        ok = native_idx == git_idx && native_rev == git_rev
        FileUtils.rm_rf(target)
        Dir.glob(git_target.sub(/\.pack\z/, ".*")).each { |path| File.delete(path) }
        Outcome.new("index-pack", ok, published.object_count.to_i64, native_time, git_time,
          ok ? "#{published.object_count} objects; .idx and .rev byte-identical" : ".idx equal: #{native_idx == git_idx}, .rev equal: #{native_rev == git_rev}")
      end
    end

    def fsck : Nil
      run("fsck") do
        report, native_time = timed { @repo.fsck }
        _, git_time = timed { git(["fsck", "--no-progress", "--no-dangling"]) }
        Outcome.new("fsck", report.ok?, report.checked.to_i64, native_time, git_time,
          report.ok? ? "#{report.checked} objects, #{report.unreachable.size} unreachable" : "corrupt #{report.corrupt.first(2)} missing #{report.missing.first(2)}")
      end
    end

    def report(io : IO) : Nil
      io << "| Check | Result | Items | Native | Git | Ratio | Detail |\n"
      io << "| --- | --- | ---: | ---: | ---: | ---: | --- |\n"
      @outcomes.each do |outcome|
        ratio = if (native = outcome.native) && (theirs = outcome.git) && theirs.total_milliseconds > 0
                  "#{(native.total_milliseconds / theirs.total_milliseconds).round(1)}x"
                else
                  ""
                end
        io << "| " << outcome.name << " | " << (outcome.passed ? "pass" : "**FAIL**") << " | " << outcome.items
        io << " | " << seconds(outcome.native) << " | " << seconds(outcome.git) << " | " << ratio
        io << " | " << outcome.detail.gsub('|', '/').gsub('\n', ' ')[0, 300] << " |\n"
      end
    end

    private def seconds(span : Time::Span?) : String
      span ? "#{span.total_seconds.round(2)}s" : ""
    end
  end
end

root = nil.as(String?)
sample = 50
seed = 1
checks = %w(objects history diffs worktree clone index-pack fsck)
remote_url = nil.as(String?)
output = nil.as(String?)
OptionParser.parse do |parser|
  parser.banner = "Usage: realworld <clone> [options]"
  parser.on("--sample N", "Commits/pairs/expressions to sample (default 50)") { |value| sample = value.to_i }
  parser.on("--seed N", "Random seed (default 1)") { |value| seed = value.to_i }
  parser.on("--checks LIST", "Comma-separated: #{checks.join(",")},https") { |value| checks = value.split(',') }
  parser.on("--https URL", "Also clone this URL natively over HTTPS") { |value| remote_url = value; checks << "https" }
  parser.on("--report FILE", "Write the Markdown table to FILE") { |value| output = value }
  parser.unknown_args { |args| root = args.first? }
end
abort "usage: realworld <clone> [options]" unless path = root
scratch = File.tempname("realworld", dir: Dir.tempdir)
Dir.mkdir_p(scratch)
runner = RealWorld::Runner.new(path, sample, seed, scratch, remote_url)
begin
  runner.objects if checks.includes?("objects")
  runner.history if checks.includes?("history")
  runner.diffs if checks.includes?("diffs")
  runner.worktree if checks.includes?("worktree")
  runner.clone_local if checks.includes?("clone")
  runner.clone_https if checks.includes?("https")
  runner.index_pack if checks.includes?("index-pack")
  runner.fsck if checks.includes?("fsck")
ensure
  FileUtils.rm_rf(scratch)
end
table = String.build { |io| runner.report(io) }
puts table
if file = output
  File.write(file, "## #{File.basename(path)}\n\n#{table}\n", mode: "a")
end
exit(runner.outcomes.all?(&.passed) ? 0 : 1)
