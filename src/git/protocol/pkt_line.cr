module Git
  # Git's wire protocol: pkt-line framing, side-band multiplexing and the
  # version 0/1 and version 2 conversations of upload-pack and
  # receive-pack.
  module Protocol
    # The remote side reported an error ("ERR ..." or side-band channel 3).
    class RemoteError < Git::Error
    end

    # The remote side spoke something this implementation does not accept.
    class ProtocolError < Git::Error
    end

    module PktLine
      MAX_LENGTH = 65_520
      MAX_DATA   = MAX_LENGTH - 4

      enum Kind
        Data
        Flush
        Delim
        ResponseEnd
      end

      record Packet, kind : Kind, data : Bytes do
        def text : String
          raw = String.new(data)
          raw.ends_with?('\n') ? raw.byte_slice(0, raw.bytesize - 1) : raw
        end

        def flush? : Bool
          kind.flush?
        end

        def delim? : Bool
          kind.delim?
        end

        def data? : Bool
          kind.data?
        end
      end

      def self.write(io : IO, data : String | Bytes) : Nil
        bytes = data.to_slice
        raise ProtocolError.new("Git pkt-line payload too long") if bytes.size > MAX_DATA
        io << (bytes.size + 4).to_s(16).rjust(4, '0')
        io.write(bytes)
      end

      # A text line, terminated with LF as Git writes them.
      def self.line(io : IO, text : String) : Nil
        write(io, text.ends_with?('\n') ? text : text + "\n")
      end

      def self.flush(io : IO) : Nil
        io << "0000"
      end

      def self.delim(io : IO) : Nil
        io << "0001"
      end

      def self.response_end(io : IO) : Nil
        io << "0002"
      end

      # Read one packet; nil at a clean end of stream. "ERR " data packets
      # raise RemoteError.
      def self.read(io : IO, *, allow_eof : Bool = false) : Packet?
        header = Bytes.new(4)
        read = io.read(header)
        if read == 0
          return nil if allow_eof
          raise ProtocolError.new("Git remote ended the stream unexpectedly")
        end
        io.read_fully(header[read, 4 - read]) if read < 4
        length = 0
        header.each do |byte|
          digit = case byte
                  when '0'.ord..'9'.ord then byte - '0'.ord
                  when 'a'.ord..'f'.ord then byte - 'a'.ord + 10
                  when 'A'.ord..'F'.ord then byte - 'A'.ord + 10
                  else                       raise ProtocolError.new("invalid Git pkt-line length #{String.new(header).inspect}")
                  end
          length = length * 16 + digit
        end
        case length
        when 0 then return Packet.new(Kind::Flush, Bytes.empty)
        when 1 then return Packet.new(Kind::Delim, Bytes.empty)
        when 2 then return Packet.new(Kind::ResponseEnd, Bytes.empty)
        when 3 then raise ProtocolError.new("invalid Git pkt-line length 3")
        end
        raise ProtocolError.new("Git pkt-line too long") if length > MAX_LENGTH
        data = Bytes.new(length - 4)
        io.read_fully(data)
        if data.size >= 4 && data[0, 4] == "ERR ".to_slice
          raise RemoteError.new("remote error: #{String.new(data[4, data.size - 4]).chomp}")
        end
        Packet.new(Kind::Data, data)
      rescue ex : IO::EOFError
        raise ProtocolError.new("Git remote ended the stream inside a packet")
      end

      # Data packets up to the next flush (or delim), as text lines.
      def self.read_section(io : IO) : {Array(String), Kind}
        lines = [] of String
        loop do
          packet = read(io).not_nil!
          return {lines, packet.kind} unless packet.data?
          lines << packet.text
        end
      end
    end

    # Demultiplexes side-band output: channel 1 is data, 2 is progress
    # text and 3 is a fatal error. The stream ends at a flush packet.
    class SidebandReader < IO
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
          raise ProtocolError.new("empty Git side-band packet") if data.empty?
          case data[0]
          when 1 then @buffer = data[1, data.size - 1]
          when 2 then @progress.try &.call(String.new(data[1, data.size - 1]))
          when 3 then raise RemoteError.new("remote error: #{String.new(data[1, data.size - 1]).chomp}")
          else        raise ProtocolError.new("invalid Git side-band channel #{data[0]}")
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
    class SidebandWriter < IO
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
