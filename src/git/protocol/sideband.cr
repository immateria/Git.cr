module Git
  module Protocol
    # Git's side-band: channel 1 carries data, 2 progress text and 3 a
    # fatal error, each in its own pkt-line.
    module Sideband
      # Reads channel 1 as a byte stream, passes channel 2 to the progress
      # callback and raises on channel 3. The stream ends at a flush packet.
      class Reader < IO
        @buffer = Bytes.empty
        @done = false

        def initialize(@io : IO, @progress : Proc(String, Nil)? = nil)
        end

        def read(slice : Bytes) : Int32
          while @buffer.empty?
            return 0 if @done
            packet = PktLine.read(@io, allow_eof: false).not_nil!
            unless packet.data?
              @done = true
              return 0
            end
            data = packet.data
            raise Violation.new("empty Git side-band packet") if data.empty?
            case data[0]
            when 1 then @buffer = data[1, data.size - 1]
            when 2 then @progress.try &.call(String.new(data[1, data.size - 1]))
            when 3 then raise RemoteFailure.new("remote error: #{String.new(data[1, data.size - 1]).chomp}")
            else        raise Violation.new("invalid Git side-band channel #{data[0]}")
            end
          end
          count = Math.min(slice.size, @buffer.size)
          slice.copy_from(@buffer[0, count])
          @buffer = @buffer[count, @buffer.size - count]
          count
        end

        def write(slice : Bytes) : Nil
          raise IO::Error.new("Git side-band reader is read-only")
        end
      end

      # Frames writes as side-band channel-1 packets (side-band-64k sizes),
      # buffering so that each packet is full. Call finish to send the rest.
      class Writer < IO
        CHUNK = PktLine::MAX_DATA - 1

        @pending : Bytes
        @used = 0

        def initialize(@io : IO, @chunk : Int32 = CHUNK)
          @pending = Bytes.new(@chunk + 1)
          @pending[0] = 1_u8
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("Git side-band writer is write-only")
        end

        def write(slice : Bytes) : Nil
          offset = 0
          while offset < slice.size
            part = Math.min(@chunk - @used, slice.size - offset)
            @pending[1 + @used, part].copy_from(slice[offset, part])
            @used += part
            offset += part
            emit if @used == @chunk
          end
        end

        def finish : Nil
          emit if @used > 0
          @io.flush
        end

        def progress(text : String) : Nil
          emit if @used > 0
          channel(2_u8, text)
        end

        def error(text : String) : Nil
          emit if @used > 0
          channel(3_u8, text)
        end

        def flush : Nil
        end

        private def emit : Nil
          PktLine.write(@io, @pending[0, @used + 1])
          @used = 0
        end

        private def channel(number : UInt8, text : String) : Nil
          packet = Bytes.new(text.bytesize + 1)
          packet[0] = number
          packet[1, text.bytesize].copy_from(text.to_slice)
          PktLine.write(@io, packet)
        end
      end
    end
  end
end
