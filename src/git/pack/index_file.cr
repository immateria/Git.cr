module Git
  module Pack
    # One object's place in a pack, as recorded in its .idx.
    record IndexEntry, oid : String, offset : Int64, crc32 : UInt32

    # The version-2 pack index (.idx): sorted object IDs with fanout, CRC32
    # and offset tables.
    module IndexFile
      LARGE_OFFSET = 0x7fff_ffff_i64

      # Byte-for-byte Git's index-pack output for the same entries.
      def self.encode(entries : Array(IndexEntry), pack_checksum : Bytes, format : ObjectId::Format) : Bytes
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
    end

    # The version-1 reverse index (.rev): .idx positions in pack order.
    module ReverseIndexFile
      def self.encode(entries : Array(IndexEntry), pack_checksum : Bytes, format : ObjectId::Format) : Bytes
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
