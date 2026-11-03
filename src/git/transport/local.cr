module Git
  module Transport
    # Another repository on this machine, served in-process by the native
    # upload-pack and receive-pack implementations (no Git subprocess).
    class Local < Base
      getter path : String

      def initialize(path : String, *,
                     @want_policy : Protocol::UploadPack::WantPolicy = Protocol::UploadPack::WantPolicy::Reachable,
                     @receive_options : Protocol::ReceivePack::Options = Protocol::ReceivePack::Options.new,
                     @max_scan_bytes : Int32 = 8_388_608,
                     @max_search_entries : Int32 = 1_000_000)
        @path = path.starts_with?("file://") ? path.byte_slice(7) : path
      end

      def url : String
        @path
      end

      def connect(service : Service, protocol_version : Int32 = 2) : Connection
        repository = Repository.new(@path, max_scan_bytes: @max_scan_bytes,
          max_search_entries: @max_search_entries)
        case service
        in .upload_pack?
          LocalConnection.new(UploadPackHandler.new(Protocol::UploadPack.new(repository, want_policy: @want_policy)))
        in .receive_pack?
          LocalConnection.new(ReceivePackHandler.new(Protocol::ReceivePack.new(repository, @receive_options)))
        end
      end

      # The in-process server behind a local connection.
      abstract class Handler
        abstract def advertise(io : IO) : Nil
        abstract def serve(input : IO, output : IO) : Nil
      end

      class UploadPackHandler < Handler
        def initialize(@server : Protocol::UploadPack)
        end

        def advertise(io : IO) : Nil
          @server.advertise(io)
        end

        def serve(input : IO, output : IO) : Nil
          @server.handle(input, output)
        end
      end

      class ReceivePackHandler < Handler
        def initialize(@server : Protocol::ReceivePack)
        end

        def advertise(io : IO) : Nil
          @server.advertise(io)
        end

        def serve(input : IO, output : IO) : Nil
          @server.handle(input, output)
        end
      end

      class LocalConnection < Connection
        @advertisement : Bytes? = nil

        def initialize(@handler : Handler)
        end

        def advertisement : Bytes
          @advertisement ||= begin
            io = IO::Memory.new
            @handler.advertise(io)
            io.to_slice
          end
        end

        def stateless? : Bool
          true
        end

        # The server writes into a pipe from its own fiber, so a large pack
        # streams to the reader without being held in memory.
        def request(body : Bytes, & : IO ->) : Nil
          reader, writer = IO.pipe
          failure = nil.as(Exception?)
          finished = Channel(Nil).new(1)
          spawn do
            begin
              @handler.serve(IO::Memory.new(body), writer)
            rescue ex
              failure = ex
            ensure
              writer.close rescue nil
              finished.send(nil)
            end
          end
          client_error = nil.as(Exception?)
          begin
            yield reader
          rescue ex
            client_error = ex
          end
          begin
            IO.copy(reader, IO::Memory.new) unless client_error
          rescue IO::Error
          end
          # Closing the reader unblocks a server that is still writing.
          reader.close rescue nil
          finished.receive
          # The server's own failure explains a client-side protocol error.
          if error = failure
            raise error if error.is_a?(Git::Error)
            raise Protocol::RemoteError.new("local server failed: #{error.class}: #{error.message}")
          end
          raise client_error if client_error
        end
      end
    end
  end
end
