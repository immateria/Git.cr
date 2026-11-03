require "socket"

module Git
  abstract class Transport
    # The git:// daemon protocol over TCP.
    class Daemon < Transport
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

      def connect(service : Service, protocol_version : Int32 = 2) : Transport::Connection
        socket = TCPSocket.new(@host, @port, connect_timeout: @connect_timeout)
        socket.read_timeout = @read_timeout
        request = "#{service.git_name} #{@path}\0host=#{@host}#{@port == DEFAULT_PORT ? "" : ":#{@port}"}\0"
        request += "\0version=#{protocol_version}\0" if protocol_version > 0
        Protocol::PktLine.write(socket, request)
        socket.flush
        Connection.new(socket)
      rescue ex : Socket::Error
        raise ConnectionFailure.new("Git daemon connection to #{@url} failed: #{ex.message}")
      end

      # The TCP stream to the daemon.
      class Connection < StreamConnection
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
    end
  end
end
