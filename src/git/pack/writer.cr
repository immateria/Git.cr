require "compress/zlib"

module Git
  module Pack
    # One object's place in a pack, as recorded in its .idx.
    record Entry, oid : String, offset : Int64, crc32 : UInt32

    # Writes a version-2 pack stream: header, entries and the trailing
    # checksum. Entries are zlib-compressed as Git writes them; deltas must
    # be encoded by the caller (see Pack::Delta).
    class Writer
      getter position : Int64 = 0_i64
      getter written : Int32 = 0
      getter count : Int32

      def initialize(@io : IO, @format : ObjectId::Format, @count : Int32,
                     @compression_level : Int32 = Compress::Zlib::DEFAULT_COMPRESSION)
        raise ArgumentError.new("invalid Git pack object count") if @count < 0
        @checksum = Checksum.new(@format)
        @crc = 0_u32
        header = IO::Memory.new
        header.write(SIGNATURE)
        header.write_bytes(2_u32, IO::ByteFormat::BigEndian)
        header.write_bytes(@count.to_u32, IO::ByteFormat::BigEndian)
        emit(header.to_slice)
      end

      # Write an undeltified object. Returns its offset and entry CRC32.
      def write_object(type : String, data : Bytes) : {Int64, UInt32}
        write_entry(ObjectDatabase::PackFiles.type_code(type), data.size.to_i64, nil, data)
      end

      # Write a delta against the earlier entry that starts at base_offset.
      def write_ofs_delta(base_offset : Int64, delta : Bytes) : {Int64, UInt32}
        raise ArgumentError.new("Git OFS_DELTA base must precede the entry") unless base_offset >= 12 && base_offset < @position
        distance = @position - base_offset
        encoded = Bytes.new(10)
        index = encoded.size - 1
        encoded[index] = (distance & 0x7f).to_u8
        while (distance >>= 7) != 0
          distance -= 1
          index -= 1
          encoded[index] = (0x80 | (distance & 0x7f)).to_u8
        end
        write_entry(6, delta.size.to_i64, encoded[index, encoded.size - index], delta)
      end

      # Write a delta against an object named by ID (inside or outside the
      # pack; a pack whose bases are outside it is "thin").
      def write_ref_delta(base_oid : String, delta : Bytes) : {Int64, UInt32}
        ObjectId.valid!(base_oid, @format)
        write_entry(7, delta.size.to_i64, base_oid.hexbytes, delta)
      end

      # Write the trailer; returns the pack checksum as hex.
      def finish : String
        raise Git::Error.new("Git pack object count differs from header (#{@written} of #{@count})") unless @written == @count
        digest = @checksum.final
        @io.write(digest)
        @position += digest.size
        @io.flush
        digest.hexstring
      end

      private def write_entry(type_code : Int32, size : Int64, base : Bytes?, data : Bytes) : {Int64, UInt32}
        raise Git::Error.new("Git pack holds more objects than its header") if @written >= @count
        offset = @position
        @crc = Digest::CRC32.initial
        header = IO::Memory.new(16)
        byte = ((type_code << 4) | (size & 0x0f)).to_u8
        rest = size >> 4
        while rest != 0
          header.write_byte(byte | 0x80)
          byte = (rest & 0x7f).to_u8
          rest >>= 7
        end
        header.write_byte(byte)
        emit(header.to_slice)
        emit(base) if base
        compressed = IO::Memory.new
        Compress::Zlib::Writer.open(compressed, level: @compression_level) { |zlib| zlib.write(data) }
        emit(compressed.to_slice)
        @written += 1
        {offset, @crc}
      end

      private def emit(bytes : Bytes) : Nil
        @io.write(bytes)
        @checksum.update(bytes)
        @crc = Digest::CRC32.update(bytes, @crc)
        @position += bytes.size
      end
    end

    # Writers for the version-2 pack index and the version-1 reverse index.
    module IndexWriter
      LARGE_OFFSET = 0x7fff_ffff_i64

      # Byte-for-byte Git's index-pack output for the same entries.
      def self.idx(entries : Array(Entry), pack_checksum : Bytes, format : ObjectId::Format) : Bytes
        sorted = entries.sort_by(&.oid)
        (1...sorted.size).each do |i|
          raise Git::Error.new("Git pack contains a duplicate object #{sorted[i].oid}") if sorted[i].oid == sorted[i - 1].oid
        end
        io = IO::Memory.new
        io.write(Bytes[0xff, 0x74, 0x4f, 0x63])
        io.write_bytes(2_u32, IO::ByteFormat::BigEndian)
        counts = Array(UInt32).new(256, 0_u32)
        sorted.each { |entry| counts[entry.oid.byte_slice(0, 2).to_i(16)] += 1 }
        total = 0_u32
        counts.each do |count|
          total += count
          io.write_bytes(total, IO::ByteFormat::BigEndian)
        end
        sorted.each { |entry| io.write(entry.oid.hexbytes) }
        sorted.each { |entry| io.write_bytes(entry.crc32, IO::ByteFormat::BigEndian) }
        large = [] of Int64
        sorted.each do |entry|
          if entry.offset > LARGE_OFFSET
            io.write_bytes(0x8000_0000_u32 | large.size.to_u32, IO::ByteFormat::BigEndian)
            large << entry.offset
          else
            io.write_bytes(entry.offset.to_u32, IO::ByteFormat::BigEndian)
          end
        end
        large.each { |offset| io.write_bytes(offset.to_u64, IO::ByteFormat::BigEndian) }
        io.write(pack_checksum)
        checksum = Checksum.new(format)
        checksum.update(io.to_slice)
        io.write(checksum.final)
        io.to_slice
      end

      # Git's .rev file: index positions in pack order.
      def self.rev(entries : Array(Entry), pack_checksum : Bytes, format : ObjectId::Format) : Bytes
        positions = entries.sort_by(&.oid).map_with_index { |entry, i| {entry.offset, i} }
        positions.sort_by! { |pair| pair[0] }
        io = IO::Memory.new
        io.write("RIDX".to_slice)
        io.write_bytes(1_u32, IO::ByteFormat::BigEndian)
        io.write_bytes(format.sha1? ? 1_u32 : 2_u32, IO::ByteFormat::BigEndian)
        positions.each { |pair| io.write_bytes(pair[1].to_u32, IO::ByteFormat::BigEndian) }
        io.write(pack_checksum)
        checksum = Checksum.new(format)
        checksum.update(io.to_slice)
        io.write(checksum.final)
        io.to_slice
      end
    end
  end
end
