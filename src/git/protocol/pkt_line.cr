module Git
  module Protocol
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
        raise Violation.new("Git pkt-line payload too long") if bytes.size > MAX_DATA
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
      # raise RemoteFailure.
      def self.read(io : IO, *, allow_eof : Bool = false) : Packet?
        header = Bytes.new(4)
        read = io.read(header)
        if read == 0
          return nil if allow_eof
          raise Violation.new("Git remote ended the stream unexpectedly")
        end
        io.read_fully(header[read, 4 - read]) if read < 4
        length = 0
        header.each do |byte|
          digit = case byte
                  when '0'.ord..'9'.ord then byte - '0'.ord
                  when 'a'.ord..'f'.ord then byte - 'a'.ord + 10
                  when 'A'.ord..'F'.ord then byte - 'A'.ord + 10
                  else                       raise Violation.new("invalid Git pkt-line length #{String.new(header).inspect}")
                  end
          length = length * 16 + digit
        end
        case length
        when 0 then return Packet.new(Kind::Flush, Bytes.empty)
        when 1 then return Packet.new(Kind::Delim, Bytes.empty)
        when 2 then return Packet.new(Kind::ResponseEnd, Bytes.empty)
        when 3 then raise Violation.new("invalid Git pkt-line length 3")
        end
        raise Violation.new("Git pkt-line too long") if length > MAX_LENGTH
        data = Bytes.new(length - 4)
        io.read_fully(data)
        if data.size >= 4 && data[0, 4] == "ERR ".to_slice
          raise RemoteFailure.new("remote error: #{String.new(data[4, data.size - 4]).chomp}")
        end
        Packet.new(Kind::Data, data)
      rescue ex : IO::EOFError
        raise Violation.new("Git remote ended the stream inside a packet")
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
  end
end
