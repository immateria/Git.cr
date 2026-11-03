require "compress/zlib"

module Git
  module Pack
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
      def write_object(type : ObjectType, data : Bytes) : {Int64, UInt32}
        write_entry(EntryType.for_object(type), data.size.to_i64, nil, data)
      end

      # Write a delta against the earlier entry that starts at base_offset.
      def write_ofs_delta(base_offset : Int64, delta : Bytes) : {Int64, UInt32}
        raise ArgumentError.new("Git OFS_DELTA base must precede the entry") unless base_offset >= 12 && base_offset < @position
        write_entry(EntryType::OfsDelta, delta.size.to_i64, EntryHeader.encode_distance(@position - base_offset), delta)
      end

      # Write a delta against an object named by ID (inside or outside the
      # pack; a pack whose bases are outside it is "thin").
      def write_ref_delta(base_oid : String, delta : Bytes) : {Int64, UInt32}
        ObjectId.valid!(base_oid, @format)
        write_entry(EntryType::RefDelta, delta.size.to_i64, base_oid.hexbytes, delta)
      end

      # Copy an entry's already-compressed data from another pack. A delta
      # is written against base_offset (OFS) or base_oid (REF).
      def write_raw(type : EntryType, size : Int64, compressed : Bytes, *,
                    base_offset : Int64? = nil, base_oid : String? = nil) : {Int64, UInt32}
        raise Git::Error.new("Git pack holds more objects than its header") if @written >= @count
        offset = @position
        @crc = Digest::CRC32.initial
        if bo = base_offset
          raise ArgumentError.new("Git OFS_DELTA base must precede the entry") unless bo >= 12 && bo < @position
          emit(EntryHeader.encode(EntryType::OfsDelta, size))
          emit(EntryHeader.encode_distance(offset - bo))
        elsif oid = base_oid
          emit(EntryHeader.encode(EntryType::RefDelta, size))
          emit(oid.hexbytes)
        else
          emit(EntryHeader.encode(type, size))
        end
        emit(compressed)
        @written += 1
        {offset, @crc}
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

      private def write_entry(type : EntryType, size : Int64, base : Bytes?, data : Bytes) : {Int64, UInt32}
        raise Git::Error.new("Git pack holds more objects than its header") if @written >= @count
        offset = @position
        @crc = Digest::CRC32.initial
        emit(EntryHeader.encode(type, size))
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
  end
end
