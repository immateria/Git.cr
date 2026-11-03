require "socket"

module Git
  module Transport
    # A stateful connection over a pair of byte streams: the service's
    # advertisement is read once, and each request is written to the
    # input and answered on the output (ssh, git://, a local program).
    abstract class StreamConnection < Connection
      @advertisement : Bytes? = nil

      abstract def reader : IO
      abstract def writer : IO

      def advertisement : Bytes
        @advertisement ||= Transport.read_advertisement(reader)
      end

      def stateless? : Bool
        false
      end

      def request(body : Bytes, & : IO ->) : Nil
        advertisement
        writer.write(body)
        writer.flush
        yield reader
      end
    end

    # Runs an explicitly chosen program for each service, e.g.
    # ["git-upload-pack", "/srv/repo.git"] or an ssh command line. The
    # program, its arguments and its whole environment come from the
    # caller; nothing is inherited unless inherit_environment is set.
    class Command < Base
      getter url : String

      def initialize(@url : String, @environment : Hash(String, String) = {} of String => String, *,
                     @inherit_environment : Bool = false,
                     @stderr : Proc(String, Nil)? = nil,
                     &@argv : Service -> Array(String))
      end

      def connect(service : Service, protocol_version : Int32 = 2) : Connection
        argv = @argv.call(service)
        raise ArgumentError.new("empty Git transport command") if argv.empty?
        environment = @environment.dup
        environment["GIT_PROTOCOL"] = "version=#{protocol_version}" if protocol_version > 0
        process = Process.new(argv[0], argv[1..], env: environment, clear_env: !@inherit_environment,
          input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
        ProcessConnection.new(process, argv[0], @stderr)
      rescue ex : File::NotFoundError | IO::Error
        raise ConnectionError.new("Git transport command #{argv.try(&.first?).inspect} failed to start: #{ex.message}")
      end
    end

    class ProcessConnection < StreamConnection
      @errors = IO::Memory.new
      @error_reader : Channel(Nil)

      def initialize(@process : ::Process, @name : String, @stderr : Proc(String, Nil)?)
        @error_reader = Channel(Nil).new(1)
        errors = @process.error
        sink = @errors
        callback = @stderr
        finished = @error_reader
        spawn do
          buffer = Bytes.new(4096)
          begin
            while (count = errors.read(buffer)) > 0
              text = String.new(buffer[0, count])
              sink.write(buffer[0, count]) if sink.size < 65_536
              callback.try &.call(text)
            end
          rescue IO::Error
          ensure
            finished.send(nil)
          end
        end
      end

      def reader : IO
        @process.output
      end

      def writer : IO
        @process.input
      end

      def advertisement : Bytes
        super
      rescue ex : Protocol::ProtocolError
        raise ConnectionError.new("#{@name} ended before advertising: #{failure_text}")
      end

      def request(body : Bytes, & : IO ->) : Nil
        super(body) { |io| yield io }
      rescue ex : Protocol::ProtocolError | IO::Error
        raise ConnectionError.new("#{@name}: #{ex.message}; #{failure_text}") unless ex.is_a?(Protocol::RemoteError)
        raise ex
      end

      def close : Nil
        @process.input.close rescue nil
        status = @process.wait
        @error_reader.receive
        @process.output.close rescue nil
        unless status.success?
          raise ConnectionError.new("#{@name} exited with status #{status.exit_code}: #{failure_text}")
        end
      end

      private def failure_text : String
        text = @errors.to_s.strip
        text.empty? ? "no error output" : text
      end
    end

    # The ssh transport: ssh://[user@]host[:port]/path and scp-like
    # [user@]host:path. ssh_command names the ssh program and options
    # (identity, known hosts); the remote runs git-upload-pack or
    # git-receive-pack, and protocol v2 is requested through GIT_PROTOCOL
    # (forwarded with SendEnv, as Git does for OpenSSH).
    class SSH < Command
      getter host : String
      getter user : String?
      getter port : Int32?
      getter path : String

      def initialize(url : String, *, ssh_command : Array(String) = ["ssh"],
                     environment : Hash(String, String) = {} of String => String,
                     inherit_environment : Bool = false,
                     stderr : Proc(String, Nil)? = nil)
        @user, @host, @port, @path = SSH.parse(url)
        user = @user
        host = @host
        port = @port
        path = @path
        command = ssh_command
        super(url, environment, inherit_environment: inherit_environment, stderr: stderr) do |service|
          argv = command.dup
          argv << "-o" << "SendEnv=GIT_PROTOCOL"
          argv << "-p" << port.to_s if port
          argv << (user ? "#{user}@#{host}" : host)
          argv << "#{service.git_name} #{SSH.quote(path)}"
          argv
        end
      end

      # {user, host, port, path} of an ssh or scp-like URL.
      def self.parse(url : String) : {String?, String, Int32?, String}
        if url.starts_with?("ssh://") || url.starts_with?("git+ssh://") || url.starts_with?("ssh+git://")
          uri = URI.parse(url.sub(/\A(git\+ssh|ssh\+git):/, "ssh:"))
          host = uri.host || raise ArgumentError.new("Git ssh URL has no host")
          path = uri.path
          path = path.byte_slice(1) if path.starts_with?("/~")
          {uri.user, host, uri.port, path}
        elsif (colon = url.index(':')) && !url.byte_slice(0, colon).includes?('/')
          authority = url.byte_slice(0, colon)
          path = url.byte_slice(colon + 1)
          user, _, host = authority.rpartition('@')
          {user.empty? ? nil : user, host, nil, path}
        else
          raise ArgumentError.new("not a Git ssh URL: #{url}")
        end
      end

      # Git's sq_quote_buf: single quotes, with ' and ! escaped.
      def self.quote(text : String) : String
        String.build do |io|
          io << '\''
          text.each_char do |char|
            if char == '\'' || char == '!'
              io << "'\\" << char << '\''
            else
              io << char
            end
          end
          io << '\''
        end
      end
    end

    # The git:// daemon protocol over TCP.
    class Daemon < Base
      DEFAULT_PORT = 9418

      getter url : String
      @host : String
      @port : Int32
      @path : String

      def initialize(@url : String, *, @connect_timeout : Time::Span = 30.seconds,
                     @read_timeout : Time::Span = 300.seconds)
        uri = URI.parse(url)
        raise ArgumentError.new("Git daemon URL must use git://") unless uri.scheme == "git"
        @host = uri.host || raise ArgumentError.new("Git daemon URL has no host")
        @port = uri.port || DEFAULT_PORT
        @path = uri.path.empty? ? "/" : uri.path
      end

      def connect(service : Service, protocol_version : Int32 = 2) : Connection
        socket = TCPSocket.new(@host, @port, connect_timeout: @connect_timeout)
        socket.read_timeout = @read_timeout
        request = "#{service.git_name} #{@path}\0host=#{@host}#{@port == DEFAULT_PORT ? "" : ":#{@port}"}\0"
        request += "\0version=#{protocol_version}\0" if protocol_version > 0
        Protocol::PktLine.write(socket, request)
        socket.flush
        SocketConnection.new(socket)
      rescue ex : Socket::Error
        raise ConnectionError.new("Git daemon connection to #{@url} failed: #{ex.message}")
      end
    end

    class SocketConnection < StreamConnection
      def initialize(@socket : TCPSocket)
      end

      def reader : IO
        @socket
      end

      def writer : IO
        @socket
      end

      def close : Nil
        @socket.close rescue nil
      end
    end

    # A transport for url, constructing ssh and git:// transports too.
    # ssh runs ssh_command; pass the options your environment needs.
    def self.for_url(url : String, *, ssh_command : Array(String)) : Base
      if url.starts_with?("git://")
        Daemon.new(url)
      elsif url.starts_with?("ssh://") || url.starts_with?("git+ssh://") || url.starts_with?("ssh+git://") ||
            ((colon = url.index(':')) && !url.byte_slice(0, colon).includes?('/') && !url.includes?("://"))
        SSH.new(url, ssh_command: ssh_command)
      else
        for_url(url)
      end
    end
  end
end
