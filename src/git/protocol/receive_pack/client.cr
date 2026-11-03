module Git
  module Protocol
    module ReceivePack
      # What a receive-pack server answered: its unpack status and, per
      # ref, nil for "ok" or the reason it gave with "ng".
      record Report, unpack : String?, statuses : Hash(String, String?) do
        def unpacked? : Bool
          unpack == "ok"
        end
      end

      # The pushing side of receive-pack (protocol version 0/1) over one
      # connection: reads the server's refs and capabilities, sends update
      # commands with a pack, and reads report-status.
      class Client
        getter advertisement : Advertisement

        def initialize(@connection : Transport::Connection)
          @advertisement = Advertisement.parse(@connection.advertisement)
          raise Violation.new("Git remote answered receive-pack with protocol v2") if @advertisement.version == 2
          raise Violation.new("Git remote does not offer report-status") unless @advertisement.capability?("report-status")
        end

        def object_format : ObjectId::Format
          @advertisement.object_format
        end

        def capability?(name : String) : Bool
          @advertisement.capability?(name)
        end

        # The server's refs and the objects they name.
        def refs : Hash(String, String)
          @advertisement.refs.to_h { |ref| {ref.name, ref.oid.not_nil!} }
        end

        # Send commands (zero IDs create or delete), then, unless every
        # command is a deletion, the pack the block writes.
        def push(commands : Array(Command), *, atomic : Bool = false,
                 progress : Proc(String, Nil)? = nil,
                 & : IO ->) : Report
          raise ArgumentError.new("Git push needs at least one command") if commands.empty?
          raise Violation.new("Git remote does not support atomic pushes") if atomic && !capability?("atomic")
          zero = ObjectId.zero(object_format)
          wanted = ["report-status"]
          wanted << "side-band-64k" if capability?("side-band-64k")
          wanted << "atomic" if atomic
          wanted << "quiet" if progress.nil? && capability?("quiet")
          wanted << "ofs-delta" if capability?("ofs-delta")
          wanted << "object-format=#{object_format.sha256? ? "sha256" : "sha1"}" if capability?("object-format")
          wanted << "agent=#{AGENT}"
          body = IO::Memory.new
          commands.each_with_index do |command, index|
            line = "#{command.old_oid} #{command.new_oid} #{command.name}"
            line += "\0#{wanted.join(' ')}" if index == 0
            PktLine.line(body, line)
          end
          PktLine.flush(body)
          yield body if commands.any? { |command| command.new_oid != zero }
          statuses = {} of String => String?
          unpack = nil.as(String?)
          @connection.request(body.to_slice) do |io|
            stream = wanted.includes?("side-band-64k") ? Sideband::Reader.new(io, progress) : io
            loop do
              packet = PktLine.read(stream, allow_eof: true)
              break if packet.nil? || packet.flush?
              text = packet.text
              if text.starts_with?("unpack ")
                unpack = text.byte_slice(7)
              elsif text.starts_with?("ok ")
                statuses[text.byte_slice(3)] = nil
              elsif text.starts_with?("ng ")
                name, _, reason = text.byte_slice(3).partition(' ')
                statuses[name] = reason.empty? ? "rejected" : reason
              end
            end
            IO.copy(stream, IO::Memory.new) if stream.is_a?(Sideband::Reader)
          end
          Report.new(unpack, statuses)
        end
      end
    end
  end
end
