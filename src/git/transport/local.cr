module Git
  abstract class Transport
    # Another repository on this machine, served in-process by the native
    # upload-pack and receive-pack servers (no Git subprocess).
    class Local < Transport
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

      def connect(service : Service, protocol_version : Int32 = 2) : Transport::Connection
        repository = begin
          Repository.new(@path, max_scan_bytes: @max_scan_bytes, max_search_entries: @max_search_entries)
        rescue ex : File::Error | Git::Error
          raise ConnectionFailure.new("Git repository #{@path} cannot be opened: #{ex.message}")
        end
        server = case service
                 in .upload_pack?  then Protocol::UploadPack::Server.new(repository, want_policy: @want_policy)
                 in .receive_pack? then Protocol::ReceivePack::Server.new(repository, @receive_options)
                 end
        Connection.new(server)
      end

      # A conversation with an in-process server.
      class Connection < Transport::Connection
        @advertisement : Bytes? = nil

        def initialize(@server : Protocol::Server)
        end

        def advertisement : Bytes
          @advertisement ||= begin
            io = IO::Memory.new
            @server.advertise(io)
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
              @server.handle(IO::Memory.new(body), writer)
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
            raise Protocol::RemoteFailure.new("local server failed: #{error.class}: #{error.message}")
          end
          raise client_error if client_error
        end
      end
    end
  end
end
