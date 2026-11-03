module Git
  # Transports carry Git's upload-pack and receive-pack conversations.
  # Every transport is explicit: the library opens no connection and runs
  # no program unless the caller constructs a transport that does.
  module Transport
    enum Service
      UploadPack
      ReceivePack

      def git_name : String
        upload_pack? ? "git-upload-pack" : "git-receive-pack"
      end
    end

    # A transport refused to authenticate or the remote rejected the
    # credentials it was given.
    class AuthenticationError < Git::Error
    end

    # The remote end could not be reached or misbehaved below the Git
    # protocol (HTTP status, connection failure).
    class ConnectionError < Git::Error
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

    abstract class Base
      # The remote location, for messages and remote configuration.
      abstract def url : String

      # Open a connection to the service, asking for protocol_version.
      abstract def connect(service : Service, protocol_version : Int32 = 2) : Connection
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
          raise Protocol::ProtocolError.new("unexpected Git packet in advertisement")
        end
      end
      output.to_slice
    end

    # Drop an HTTP smart-protocol "# service=..." line and its flush.
    def self.strip_service_preamble(raw : Bytes, service : Service) : Bytes
      io = IO::Memory.new(raw)
      first = Protocol::PktLine.read(io, allow_eof: true)
      return raw unless first && first.data? && first.text.starts_with?("# service=")
      raise Protocol::ProtocolError.new("Git remote advertised #{first.text} for #{service.git_name}") unless first.text == "# service=#{service.git_name}"
      second = Protocol::PktLine.read(io).not_nil!
      raise Protocol::ProtocolError.new("Git service preamble lacks its flush") unless second.flush?
      raw[io.pos, raw.size - io.pos]
    end
  end
end
