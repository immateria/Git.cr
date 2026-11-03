module Git
  abstract class Transport
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
  end
end
