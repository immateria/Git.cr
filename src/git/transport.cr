module Git
  # A way to reach one remote repository's upload-pack and receive-pack
  # services. Every transport is explicit: the library opens no connection
  # and runs no program unless the caller constructs a transport that does.
  # Subclasses: Transport::Local, Transport::HTTP, Transport::Command (and
  # its Transport::SSH form) and Transport::Daemon.
  abstract class Transport
    enum Service
      UploadPack
      ReceivePack

      def git_name : String
        upload_pack? ? "git-upload-pack" : "git-receive-pack"
      end
    end

    # The remote refused the credentials it was given, or none were
    # available when it asked for them.
    class AuthenticationFailure < Git::Error
    end

    # The remote end could not be reached or misbehaved below the Git
    # protocol (HTTP status, connection or program failure).
    class ConnectionFailure < Git::Error
    end

    record Credential, username : String, password : String

    # Supplies credentials for a URL, or nil to give up. attempt counts
    # from 1 and grows after each rejection.
    alias CredentialProvider = Proc(String, Int32, Credential?)

    # One open conversation with a remote service.
    abstract class Connection
      # The service's first output with any HTTP "# service=" preamble
      # removed: a version 2 capability advertisement or a version 0/1
      # reference advertisement, as pkt-lines through the final flush.
      abstract def advertisement : Bytes

      # Send one request and read its response. Stateless transports
      # (HTTP) make one round trip per request; stateful ones write the
      # body to the open channel and read the reply from it.
      abstract def request(body : Bytes, & : IO ->) : Nil

      # Whether each request stands alone (Git's stateless-rpc).
      abstract def stateless? : Bool

      def close : Nil
      end
    end

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

    # The remote location, for messages and remote configuration.
    abstract def url : String

    # Open a connection to the service, asking for protocol_version.
    abstract def connect(service : Service, protocol_version : Int32 = 2) : Connection

    # A transport for url: smart HTTP(S) or a local repository. Other
    # schemes (ssh, git://) need ssh_command or an explicitly constructed
    # transport.
    def self.for_url(url : String) : Transport
      if url.starts_with?("http://") || url.starts_with?("https://")
        HTTP.new(url)
      elsif url.starts_with?("file://") || url.starts_with?('/') || url.starts_with?('.') || !url.includes?(':')
        Local.new(url)
      else
        raise Error.new("Git transport for #{url} must be supplied explicitly (no ssh or git:// transport is opened implicitly)")
      end
    end

    # A transport for url, constructing ssh and git:// transports too.
    # ssh runs ssh_command; pass the options your environment needs.
    def self.for_url(url : String, *, ssh_command : Array(String)) : Transport
      if url.starts_with?("git://")
        Daemon.new(url)
      elsif url.starts_with?("ssh://") || url.starts_with?("git+ssh://") || url.starts_with?("ssh+git://") ||
            ((colon = url.byte_index(':')) && !url.byte_slice(0, colon).includes?('/') && !url.includes?("://"))
        SSH.new(url, ssh_command: ssh_command)
      else
        for_url(url)
      end
    end

    # Read pkt-lines through the first flush into a byte string.
    def self.read_advertisement(io : IO) : Bytes
      output = IO::Memory.new
      loop do
        packet = Protocol::PktLine.read(io).not_nil!
        if packet.data?
          Protocol::PktLine.write(output, packet.data)
        elsif packet.flush?
          Protocol::PktLine.flush(output)
          break
        else
          raise Protocol::Violation.new("unexpected Git packet in advertisement")
        end
      end
      output.to_slice
    end

    # Drop an HTTP smart-protocol "# service=..." line and its flush.
    def self.strip_service_preamble(raw : Bytes, service : Service) : Bytes
      io = IO::Memory.new(raw)
      first = Protocol::PktLine.read(io, allow_eof: true)
      return raw unless first && first.data? && first.text.starts_with?("# service=")
      raise Protocol::Violation.new("Git remote advertised #{first.text} for #{service.git_name}") unless first.text == "# service=#{service.git_name}"
      second = Protocol::PktLine.read(io).not_nil!
      raise Protocol::Violation.new("Git service preamble lacks its flush") unless second.flush?
      raw[io.pos, raw.size - io.pos]
    end
  end
end

require "./transport/local"
require "./transport/http"
require "./transport/command"
require "./transport/ssh"
require "./transport/daemon"
