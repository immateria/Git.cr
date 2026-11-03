require "spec"
require "file_utils"
require "socket"
require "../src/git"
require "./support/git_oracle"

private SIGNATURE = Git::Signature.new("Transport Test", "transport@example.invalid", 1_700_000_000_i64, 0)

private def oracle_bin_dir : String
  File.dirname(Process.find_executable(GitOracle::GIT_BINARY) || raise "Git oracle binary not found")
end

private def oracle_environment(home : String) : Hash(String, String)
  {
    "PATH"                => "#{oracle_bin_dir}:/usr/bin:/bin",
    "HOME"                => home,
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_GLOBAL"   => "/dev/null",
  }
end

private def transport_source(root : String) : String
  File.write(File.join(root, "a.txt"), "a\n")
  GitOracle.run(root, "add", "a.txt")
  GitOracle.run(root, "commit", "-qm", "first")
  File.write(File.join(root, "b.txt"), "b\n")
  GitOracle.run(root, "add", "b.txt")
  GitOracle.run(root, "commit", "-qm", "second")
  GitOracle.run(root, "tag", "-a", "v1", "-m", "v1\n")
  GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
end

# Clone through the transport, commit, push back, and check both ends.
private def round_trip(transport : Git::Transport::Base, bare : String, clone : String) : Nil
  repo = Git::Repository.clone(transport, clone, url: transport.url)
  GitOracle.run(clone, "fsck", "--strict", "--no-dangling")
  GitOracle.run(clone, "status", "--porcelain").stdout.should eq("")
  repo.resolve_ref?("refs/tags/v1").should eq(GitOracle.run(bare, "rev-parse", "v1").stdout.strip)
  File.write(File.join(clone, "c.txt"), "c\n")
  repo.stage_file("c.txt")
  commit = repo.commit_staged(author: SIGNATURE, committer: SIGNATURE, message: "third\n")
  repo.push("origin", ["main", "main:refs/heads/copy"], transport: transport).success?.should be_true
  GitOracle.run(bare, "rev-parse", "main", "copy").stdout.lines.should eq([commit, commit])
  GitOracle.run(bare, "fsck", "--strict", "--no-dangling")
  repo.fetch(transport: transport).rejected.should be_empty
end

describe "Git transports" do
  it "TRANSPORT-O01 runs explicitly chosen git-upload-pack and git-receive-pack programs" do
    GitOracle.with_repo do |source|
      transport_source(source)
      base = File.dirname(source)
      bare = File.join(base, "bare.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, bare)
      seen = [] of Git::Transport::Service
      transport = Git::Transport::Command.new(bare, oracle_environment(base)) do |service|
        seen << service
        [GitOracle::GIT_BINARY, service.upload_pack? ? "upload-pack" : "receive-pack", bare]
      end
      round_trip(transport, bare, File.join(base, "clone"))
      seen.should contain(Git::Transport::Service::UploadPack)
      seen.should contain(Git::Transport::Service::ReceivePack)

      failing = Git::Transport::Command.new(bare, oracle_environment(base)) do |_|
        [GitOracle::GIT_BINARY, "upload-pack", File.join(base, "missing.git")]
      end
      expect_raises(Git::Transport::ConnectionError, /missing\.git|not appear to be a git repository/) do
        Git::Repository.new(source).ls_remote(failing)
      end
    end
  end

  it "TRANSPORT-O02 speaks the git:// daemon protocol" do
    GitOracle.with_repo do |source|
      transport_source(source)
      base = File.dirname(source)
      bare = File.join(base, "served.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, bare)
      port = TCPServer.open("127.0.0.1", 0) { |server| server.local_address.port }
      daemon = Process.new(GitOracle::GIT_BINARY, ["daemon", "--reuseaddr", "--export-all", "--enable=receive-pack",
        "--base-path=#{base}", "--listen=127.0.0.1", "--port=#{port}", base],
        env: oracle_environment(base), clear_env: true, error: Process::Redirect::Close)
      begin
        ready = false
        100.times do
          begin
            TCPSocket.new("127.0.0.1", port).close
            ready = true
            break
          rescue Socket::Error
            sleep 0.1.seconds
          end
        end
        raise "git daemon did not start" unless ready
        transport = Git::Transport::Daemon.new("git://127.0.0.1:#{port}/served.git")
        refs = Git::Repository.new(source).ls_remote(transport)
        refs.map(&.name).should contain("refs/heads/main")
        round_trip(transport, bare, File.join(base, "clone"))
      ensure
        daemon.terminate rescue nil
        daemon.wait rescue nil
      end
    end
  end

  it "TRANSPORT-O03 runs ssh with Git's argument layout and quoting" do
    GitOracle.with_repo do |source|
      transport_source(source)
      base = File.dirname(source)
      bare = File.join(base, "it's here!.git")
      GitOracle.run(base, "clone", "-q", "--bare", "--no-local", source, bare)
      log = File.join(base, "ssh.log")
      fake = File.join(base, "fake-ssh")
      # Record the arguments, check that GIT_PROTOCOL is offered for
      # forwarding, then run the remote command locally as sshd would.
      File.write(fake, <<-SH)
        #!/bin/sh
        printf '%s\\n' "$@" >> '#{log}'
        for last; do :; done
        exec /bin/sh -c "$last"
        SH
      File.chmod(fake, 0o755)
      transport = Git::Transport::SSH.new("ssh://tester@example.invalid:2222#{bare}",
        ssh_command: [fake], environment: oracle_environment(base))
      round_trip(transport, bare, File.join(base, "clone"))
      arguments = File.read(log).lines
      arguments.first(6).should eq(["-o", "SendEnv=GIT_PROTOCOL", "-p", "2222", "tester@example.invalid",
        "git-upload-pack #{Git::Transport::SSH.quote(bare)}"])
      arguments.should contain("git-receive-pack #{Git::Transport::SSH.quote(bare)}")
    end
  end

  it "TRANSPORT-O04 parses ssh and scp-like URLs" do
    Git::Transport::SSH.parse("ssh://git@github.com/immateria/Git.cr.git").should eq({"git", "github.com", nil, "/immateria/Git.cr.git"})
    Git::Transport::SSH.parse("ssh://host:2200/~user/repo").should eq({nil, "host", 2200, "~user/repo"})
    Git::Transport::SSH.parse("git@github.com:immateria/Git.cr.git").should eq({"git", "github.com", nil, "immateria/Git.cr.git"})
    Git::Transport::SSH.parse("host:path/to/repo").should eq({nil, "host", nil, "path/to/repo"})
    Git::Transport::SSH.quote("a'b!c").should eq("'a'\\''b'\\!'c'")
    Git::Transport.for_url("git@github.com:x/y.git", ssh_command: ["ssh"]).should be_a(Git::Transport::SSH)
    Git::Transport.for_url("git://example.invalid/x", ssh_command: ["ssh"]).should be_a(Git::Transport::Daemon)
    Git::Transport.for_url("https://example.invalid/x").should be_a(Git::Transport::HTTP)
    Git::Transport.for_url("/srv/repo.git").should be_a(Git::Transport::Local)
    expect_raises(Git::Error, /explicitly/) { Git::Transport.for_url("git@github.com:x/y.git") }
  end
end
