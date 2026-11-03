module Git
  module Pack
    # Git's binary delta format: a copy/insert program that rebuilds a
    # target from a source. The encoder indexes the source in 16-byte
    # blocks and greedily extends exact matches in both directions, the
    # approach of Git's diff-delta.c.
    module Delta
      BLOCK    =      16
      MAX_COPY = 0x10000

      # A source indexed once and reused for many targets.
      class Index
        getter source : Bytes

        def initialize(@source : Bytes)
          @table = Delta.build_index(@source)
        end

        def encode(target : Bytes, max_size : Int64 = Int64::MAX) : Bytes?
          Delta.encode_with(@source, @table, target, max_size)
        end
      end

      # Encode target as a delta against source. Returns nil when the delta
      # would not be smaller than max_size bytes.
      def self.encode(source : Bytes, target : Bytes, max_size : Int64 = Int64::MAX) : Bytes?
        encode_with(source, build_index(source), target, max_size)
      end

      protected def self.encode_with(source : Bytes, index : Hash(UInt64, Array(Int32)),
                                     target : Bytes, max_size : Int64) : Bytes?
        output = IO::Memory.new(Math.min(target.size // 2 + 32, 1 << 20))
        write_varint(output, source.size.to_u64)
        write_varint(output, target.size.to_u64)
        literal_start = 0
        position = 0
        limit = target.size - BLOCK
        while position <= limit
          match_offset = -1
          match_length = 0
          match_back = 0
          if !index.empty? && (candidates = index[key(target, position)]?)
            candidates.each do |offset|
              next unless block_equal?(source, offset, target, position)
              length = BLOCK
              while offset + length < source.size && position + length < target.size &&
                    source[offset + length] == target[position + length]
                length += 1
              end
              back = 0
              while position - back > literal_start && offset - back > 0 &&
                    source[offset - back - 1] == target[position - back - 1]
                back += 1
              end
              if length + back > match_length + match_back
                match_offset = offset
                match_length = length
                match_back = back
              end
            end
          end
          if match_offset >= 0
            emit_literal(output, target, literal_start, position - match_back)
            emit_copy(output, match_offset - match_back, match_length + match_back)
            position += match_length
            literal_start = position
            return nil if output.size >= max_size
          else
            position += 1
          end
        end
        emit_literal(output, target, literal_start, target.size)
        return nil if output.size >= max_size
        output.to_slice
      end

      protected def self.build_index(source : Bytes) : Hash(UInt64, Array(Int32))
        index = {} of UInt64 => Array(Int32)
        return index if source.size < BLOCK
        offset = 0
        while offset + BLOCK <= source.size
          list = index[key(source, offset)] ||= [] of Int32
          # Keep a few candidates per key, as Git limits its hash buckets.
          list << offset if list.size < 8
          offset += BLOCK
        end
        index
      end

      private def self.key(bytes : Bytes, offset : Int32) : UInt64
        pointer = bytes.to_unsafe + offset
        first = pointer.as(UInt64*).value
        second = (pointer + 8).as(UInt64*).value
        first &* 0x9e37_79b9_7f4a_7c15_u64 ^ second
      end

      private def self.block_equal?(source : Bytes, offset : Int32, target : Bytes, position : Int32) : Bool
        (source.to_unsafe + offset).memcmp(target.to_unsafe + position, BLOCK) == 0
      end

      private def self.emit_literal(output : IO, target : Bytes, start : Int32, finish : Int32) : Nil
        while start < finish
          length = Math.min(127, finish - start)
          output.write_byte(length.to_u8)
          output.write(target[start, length])
          start += length
        end
      end

      private def self.emit_copy(output : IO, offset : Int32, length : Int32) : Nil
        while length > 0
          part = Math.min(length, MAX_COPY)
          opcode = 0x80_u8
          encoded = Bytes.new(7)
          used = 0
          4.times do |i|
            byte = ((offset >> (i * 8)) & 0xff).to_u8
            next if byte == 0
            opcode |= (1 << i).to_u8
            encoded[used] = byte
            used += 1
          end
          size = part == MAX_COPY ? 0 : part
          3.times do |i|
            byte = ((size >> (i * 8)) & 0xff).to_u8
            next if byte == 0
            opcode |= (0x10 << i).to_u8
            encoded[used] = byte
            used += 1
          end
          output.write_byte(opcode)
          output.write(encoded[0, used])
          offset += part
          length -= part
        end
      end

      private def self.write_varint(output : IO, value : UInt64) : Nil
        loop do
          byte = (value & 0x7f).to_u8
          value >>= 7
          if value == 0
            output.write_byte(byte)
            break
          end
          output.write_byte(byte | 0x80)
        end
      end
    end
  end
end
