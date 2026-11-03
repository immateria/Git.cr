require "file_utils"

# A deterministic upstream-Git oracle for disposable source-only git specs.
# Never use this in the shipped Git implementation; external programs and
# repository hooks belong exclusively to fixtures or an explicit host runner.
module GitOracle
  class Mismatch < Exception
  end

  record Result, stdout : String, stderr : String, exit_code : Int32 do
    def success? : Bool
      exit_code == 0
    end
  end

  # Pin the deterministic fixture oracle. The binary can be supplied by a
  # nonstandard toolchain without changing the runtime or its tests.
  # Oracle test entrypoints require Git 2.47.3, regardless of host Git.
  GIT_BINARY     = ENV["GIT_ORACLE_BINARY"]? || "git"
  ORACLE_VERSION = "git version 2.47.3"
  VERSION        = begin
    output = IO::Memory.new
    errors = IO::Memory.new
    status = Process.run(GIT_BINARY, ["--version"],
      env: {"PATH" => "/usr/bin:/bin"}, clear_env: true,
      output: output, error: errors)
    observed = output.to_s.strip
    raise "Git oracle requires #{ORACLE_VERSION}, got #{observed.inspect} from #{GIT_BINARY.inspect} (set GIT_ORACLE_BINARY)" unless status.success? && observed == ORACLE_VERSION
    observed
  end

  def self.verify_version! : Nil
    raise "Git oracle version check failed" unless VERSION == ORACLE_VERSION
  end

  # This deliberately does not inherit any GIT_* or XDG_/HOME environment.
  # Global/system config, template hooks, prompts and ambient credentials
  # cannot change the fixture semantics.
  def self.run(root : String, *args : String, input : String? = nil, check : Bool = true,
               extra_env : Hash(String, String)? = nil) : Result
    verify_version!
    home = File.join(File.dirname(root), "oracle-home")
    Dir.mkdir_p(home)
    environment = {
      "PATH"                => "/usr/bin:/bin",
      "HOME"                => home,
      "XDG_CONFIG_HOME"     => File.join(home, ".config"),
      "LANG"                => "C",
      "LC_ALL"              => "C",
      "TZ"                  => "UTC",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL"   => "/dev/null",
      "GIT_CONFIG_SYSTEM"   => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME"     => "Git Oracle",
      "GIT_AUTHOR_EMAIL"    => "oracle@example.invalid",
      "GIT_COMMITTER_NAME"  => "Git Oracle",
      "GIT_COMMITTER_EMAIL" => "oracle@example.invalid",
      "GIT_SSH_COMMAND"     => "/bin/false",
    }
    extra_env.try &.each { |key, value| environment[key] = value }
    output = IO::Memory.new
    errors = IO::Memory.new
    status = Process.run(GIT_BINARY, ["-C", root] + args.to_a,
      env: environment, clear_env: true, input: input ? IO::Memory.new(input) : Process::Redirect::Close,
      output: output, error: errors)
    result = Result.new(output.to_s, errors.to_s, status.exit_code)
    if check && !result.success?
      raise "Git oracle #{args} failed (exit #{result.exit_code}): #{result.stderr}"
    end
    result
  end

  # Whether the temporary directory's file system takes a file name that is
  # not UTF-8. Linux's take any bytes but '/' and NUL; Apple's refuse one
  # (EILSEQ), so neither a work-tree file nor a loose ref can carry it there.
  RAW_NAMES = begin
    probe = File.join(File.realpath(Dir.tempdir), "git-oracle-#{Process.pid}-" + String.new(Bytes[0xff]))
    File.write(probe, "")
    File.delete(probe)
    true
  rescue ex : File::Error
    raise ex unless ex.os_error == Errno::EILSEQ
    false
  end

  def self.storable?(name : String) : Bool
    RAW_NAMES || name.valid_encoding?
  end

  # Puts *content* in the index under *name* with no file in the work tree,
  # as Git would stage a file of that name: for a name the file system
  # refuses.
  def self.stage_blob(root : String, name : String, content : String) : String
    oid = run(root, "hash-object", "-w", "--stdin", input: content).stdout.strip
    run(root, "update-index", "--add", "--cacheinfo", "100644,#{oid},#{name}")
    oid
  end

  def self.with_repo(*, format : String = "sha1", &block : String ->) : Nil
    raise ArgumentError.new("unknown fixture object format") unless {"sha1", "sha256"}.includes?(format)
    base = File.tempname("git-oracle", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(base)
    root = File.join(base, "repo")
    Dir.mkdir_p(root)
    Dir.mkdir_p(File.join(base, "empty-template"))
    begin
      run(root, "init", "-q", "--initial-branch=main", "--object-format=#{format}",
        "--template=#{File.join(base, "empty-template")}")
      yield root
    ensure
      FileUtils.rm_rf(base)
    end
  end

  # Byte-exact comparison: preserves NULs and invalid UTF-8 without line
  # splitting, trailing whitespace trimming or text normalization.
  def self.assert_bytes!(actual : String, expected : String, fixture_id : String) : Nil
    return if actual.to_slice == expected.to_slice
    raise Mismatch.new("#{fixture_id}: Git oracle byte mismatch")
  end
end

# Enforce the pinned oracle at suite startup, not after the first fixture runs.
GitOracle.verify_version!
