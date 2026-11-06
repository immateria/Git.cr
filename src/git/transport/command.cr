module Git
  abstract class Transport
    # Runs an explicitly chosen program for each service, e.g.
    # ["git-upload-pack", "/srv/repo.git"] or an ssh command line. The
    # program, its arguments and its whole environment come from the
    # caller; nothing is inherited unless inherit_environment is set.
    class Command < Transport
      getter url : String

      def initialize(@url : String, @environment : Hash(String, String) = {} of String => String, *,
                     @inherit_environment : Bool = false,
                     @stderr : Proc(String, Nil)? = nil,
                     &@argv : Service -> Array(String))
      end

      def connect(service : Service, protocol_version : Int32 = 2) : Transport::Connection
        argv = @argv.call(service)
        raise ArgumentError.new("empty Git transport command") if argv.empty?
        environment = @environment.dup
        environment["GIT_PROTOCOL"] = "version=#{protocol_version}" if protocol_version > 0
        process = Process.new(argv[0], argv[1..], env: environment, clear_env: !@inherit_environment,
          input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
        Connection.new(process, argv[0], @stderr)
      rescue ex : File::NotFoundError | IO::Error
        raise ConnectionFailure.new("Git transport command #{argv.try(&.first?).inspect} failed to start: #{ex.message}")
      end

      # The running program's stdin and stdout; its stderr is collected
      # for failure messages and passed to the stderr callback.
      class Connection < StreamConnection
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
        rescue ex : Protocol::Violation
          raise ConnectionFailure.new("#{@name} ended before advertising: #{failure_text}")
        end

        def request(body : Bytes, & : IO ->) : Nil
          super(body) { |io| yield io }
        rescue ex : Protocol::Violation | IO::Error
          raise ConnectionFailure.new("#{@name}: #{ex.message}; #{failure_text}")
        end

        def close : Nil
          @process.input.close rescue nil
          status = @process.wait
          @error_reader.receive
          @process.output.close rescue nil
          unless status.success?
            raise ConnectionFailure.new("#{@name} exited with status #{status.exit_code}: #{failure_text}")
          end
        end

        private def failure_text : String
          text = @errors.to_s.strip
          text.empty? ? "no error output" : text
        end
      end
    end
  end
end
