require "compress/zlib"
require "set"

module Git
  # Pack index v2 lookup and compressed delta reconstruction. The only
  # caller supplies an object-ID resolver for REF_DELTA parent lookup.
  class ObjectDatabase
    class PackFiles
      MAX_PACKS              =          64
      MAX_INDEX_BYTES        = 134_217_728
      MAX_PACKED_ENTRY_BYTES =  67_108_864

      def initialize(@common : String, @object_format : ObjectId::Format)
        @pack_filename = Regex.new("\\Apack-[0-9a-f]{#{@object_format.hexsize}}\\.idx\\z")
      end

      def find_packed(oid : String) : {String, Int64}?
        directory = File.join(@common, "objects", "pack")
        return nil unless Dir.exists?(directory)
        raise Git::Error.new("Git pack directory redirected") unless !File.symlink?(directory) && Dir.exists?(directory) && File.realpath(directory) == directory
        count = 0
        Dir.each_child(directory) do |entry|
          next unless entry.matches?(@pack_filename)
          count += 1
          raise Git::Error.new("Git pack file count exceeded") if count > MAX_PACKS
          idx_path = File.join(directory, entry)
          pack_path = File.join(directory, entry.sub(/\.idx\z/, ".pack"))
          next unless File.file?(pack_path)
          if offset = index_lookup(idx_path, pack_path, oid)
            return {pack_path, offset}
          end
        end
        nil
      end

      # Index layout and repository-format checksum are verified before offsets are trusted.
      # This deliberately costs O(index size) per lookup: no mutable on-disk
      # metadata is cached across calls while an untrusted repo can change it.
      private def index_lookup(idx : String, pack : String, oid : String) : Int64?
        raise Git::Error.new("Git pack index redirected") if File.symlink?(idx) || File.realpath(idx) != idx
        input = IO::Memory.new
        File.open(idx) { |io| IO.copy(io, input, MAX_INDEX_BYTES + 1_i64) }
        raise Git::Error.new("Git pack index byte budget exceeded") if input.size > MAX_INDEX_BYTES
        raw = input.to_s
        hash_size = @object_format.bytesize
        raise Git::Error.new("Git pack index truncated") if raw.bytesize < 8 + 1024 + 2 * hash_size
        body_size = raw.bytesize - hash_size
        raise Git::Error.new("Git pack index checksum mismatch") unless ObjectId.checksum(raw.byte_slice(0, body_size), @object_format) == raw.byte_slice(body_size, hash_size).to_slice.hexstring

        io = IO::Memory.new(raw)
        raise Git::Error.new("Git pack index v2 required") unless read_bytes_exact(io, 4).hexstring == "ff744f63" &&
                                                                  io.read_bytes(UInt32, IO::ByteFormat::BigEndian) == 2
        fanout = Array(UInt32).new(256) { io.read_bytes(UInt32, IO::ByteFormat::BigEndian) }
        previous = 0_u32
        fanout.each do |count|
          raise Git::Error.new("Git pack fanout invalid") if count < previous
          previous = count
        end
        total = fanout.last.to_i64
        raise Git::Error.new("Git pack index count exceeds budget") if total > 2_000_000 || total == 0
        table = 8_i64 + 1024
        large_start = table + total * (hash_size + 8)
        raise Git::Error.new("Git pack index tables truncated") if large_start + 2 * hash_size > raw.bytesize
        extra = raw.bytesize.to_i64 - large_start - 2 * hash_size
        raise Git::Error.new("Git pack index large-offset table invalid") unless extra % 8 == 0 && extra // 8 <= total
        large_count = extra // 8

        # The fanout and sorted ID table must agree even if an attacker
        # recomputes the index checksum after changing the metadata.
        counts = Array(Int64).new(256, 0_i64)
        prior = nil.as(String?)
        total.times do |row|
          pos = (table + row * hash_size).to_i
          current = raw.byte_slice(pos, hash_size)
          raise Git::Error.new("Git pack object IDs out of order") if prior && prior >= current
          counts[raw.byte_at(pos).to_i] += 1
          prior = current
        end
        cumulative = 0_i64
        256.times do |i|
          cumulative += counts[i]
          raise Git::Error.new("Git pack fanout does not match IDs") unless cumulative == fanout[i]
        end

        first = oid.byte_slice(0, 2).to_i(16)
        low = first.zero? ? 0_i64 : fanout[first - 1].to_i64
        high = fanout[first].to_i64
        wanted = oid.hexbytes
        while low < high
          mid = low + (high - low) // 2
          io.seek(table + mid * hash_size)
          probe = read_bytes_exact(io, hash_size)
          comparison = probe.to_a <=> wanted.to_a
          if comparison == 0
            io.seek(table + total * (hash_size + 4) + mid * 4)
            encoded = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
            offset = packed_offset(io, encoded, large_start, large_count)
            pack_end = verify_pack_link!(pack, total, raw.byte_slice(raw.bytesize - 2 * hash_size, hash_size).to_slice, offset)
            next_entry = pack_end
            offset_table = table + total * (hash_size + 4)
            total.times do |row|
              io.seek(offset_table + row * 4)
              row_offset = packed_offset(io, io.read_bytes(UInt32, IO::ByteFormat::BigEndian), large_start, large_count)
              raise Git::Error.new("Git pack offset out of bounds") unless row_offset >= 12 && row_offset < pack_end
              raise Git::Error.new("Git pack offsets duplicate") if row != mid && row_offset == offset
              next_entry = row_offset if row_offset > offset && row_offset < next_entry
            end
            io.seek(table + total * hash_size + mid * 4)
            expected_crc = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
            verify_packed_crc!(pack, offset, next_entry, expected_crc)
            return offset
          elsif comparison && comparison < 0
            low = mid + 1
          else
            high = mid
          end
        end
        nil
      rescue ex : IO::Error
        raise Git::Error.new("Git pack index I/O invalid: #{ex.class}")
      end

      private def packed_offset(io : IO, encoded : UInt32, large_start : Int64, large_count : Int64) : Int64
        if (encoded & 0x8000_0000_u32) == 0
          return encoded.to_i64
        end
        entry = (encoded & 0x7fff_ffff_u32).to_i64
        raise Git::Error.new("Git pack large-offset reference invalid") if entry >= large_count
        io.seek(large_start + entry * 8)
        huge = io.read_bytes(UInt64, IO::ByteFormat::BigEndian)
        raise Git::Error.new("Git pack large offset exceeds integer range") if huge > Int64::MAX
        huge.to_i64
      end

      # Git index CRC32 covers the full packed entry, from its type/size
      # header through its compressed bytes (not the expanded object).
      private def verify_packed_crc!(pack : String, start : Int64, finish : Int64, expected : UInt32) : Nil
        length = finish - start
        raise Git::Error.new("Git packed entry byte budget exceeded") if length <= 0 || length > MAX_PACKED_ENTRY_BYTES
        crc = 0xffff_ffff_u32
        File.open(pack) do |io|
          io.seek(start)
          buffer = Bytes.new(16_384)
          remaining = length
          while remaining > 0
            part = remaining < buffer.size ? remaining.to_i : buffer.size
            chunk = buffer[0, part]
            io.read_fully(chunk)
            chunk.each do |byte|
              crc ^= byte.to_u32
              8.times do
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320_u32 : 0_u32)
              end
            end
            remaining -= part
          end
        end
        raise Git::Error.new("Git packed object CRC mismatch") unless ~crc == expected
      end

      # Pair the index with precisely the pack it describes, not merely a
      # similarly-named file. The requested object is independently SHA-1/SHA-256
      # verified by Git::ObjectDatabase; this does not hash an entire multi-GB pack.
      private def verify_pack_link!(pack : String, indexed_count : Int64, checksum : Bytes, offset : Int64) : Int64
        raise Git::Error.new("Git pack redirected") if File.symlink?(pack) || File.realpath(pack) != pack
        File.open(pack) do |io|
          raise Git::Error.new("Git pack truncated") if io.size < 12 + @object_format.bytesize
          raise Git::Error.new("unsupported Git pack") unless read_bytes_exact(io, 4).hexstring == "5041434b"
          version = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("unsupported Git pack version") unless {2_u32, 3_u32}.includes?(version)
          count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("Git pack object count differs from index") unless count.to_i64 == indexed_count
          raise Git::Error.new("Git pack offset out of bounds") unless offset >= 12 && offset < io.size - @object_format.bytesize
          io.seek(io.size - @object_format.bytesize)
          raise Git::Error.new("Git pack checksum differs from index") unless read_bytes_exact(io, @object_format.bytesize) == checksum
          io.size - @object_format.bytesize
        end
      end

      def decode_pack(file : String, offset : Int64, max : Int32, depth : Int32, seen : Set(String), resolve_oid : Proc(String, Int32, Set(String), {String, String}), &check : -> Nil) : {String, String}
        raise Git::Error.new("Git pack redirected") if File.symlink?(file) || File.realpath(file) != file
        raise Git::Error.new("Git delta chain too deep") if depth >= 24
        File.open(file) do |io|
          raise Git::Error.new("unsupported Git pack") unless read_bytes_exact(io, 4).hexstring == "5041434b"
          ver = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("unsupported Git pack version") unless {2_u32, 3_u32}.includes?(ver)
          count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("Git pack has no objects") if count == 0
          raise Git::Error.new("Git pack offset out of bounds") unless offset >= 12 && offset < io.size - @object_format.bytesize
          io.seek(offset)
          b = io.read_byte || raise Git::Error.new("truncated Git pack object")
          size = (b & 0x0f).to_i64
          type_code = (b >> 4) & 7
          shift = 4
          while (b & 0x80) != 0
            b = io.read_byte || raise Git::Error.new("truncated Git object size")
            raise Git::Error.new("Git object size invalid") if shift > 35
            size |= (b & 0x7f).to_i64 << shift
            shift += 7
          end
          raise Git::Error.new("Git object exceeds byte budget") if size > max
          base_offset = nil.as(Int64?)
          base_oid = nil.as(String?)
          if type_code == 6
            byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
            distance = (byte & 0x7f).to_i64
            while (byte & 0x80) != 0
              byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
              raise Git::Error.new("Git delta distance overflows") if distance >= (Int64::MAX >> 7) - 1
              distance = ((distance + 1) << 7) | (byte & 0x7f).to_i64
              raise Git::Error.new("invalid Git delta distance") if distance >= offset
            end
            raise Git::Error.new("invalid Git delta parent offset") if distance <= 0 || offset - distance < 12
            base_offset = offset - distance
          elsif type_code == 7
            base_oid = read_bytes_exact(io, @object_format.bytesize).hexstring
          elsif !{1, 2, 3, 4}.includes?(type_code)
            raise Git::Error.new("unsupported Git pack entry type")
          end
          inflated = Compress::Zlib::Reader.open(io) { |z| bounded_decompress(z, max + 128) }
          check.call
          if type_code == 6 || type_code == 7
            raise Git::Error.new("Git packed delta instruction size mismatch") unless inflated.bytesize == size
            kind, base = if bo = base_offset
                           decode_pack(file, bo, max, depth + 1, seen, resolve_oid) { check.call }
                         else
                           resolve_oid.call(base_oid.not_nil!, depth + 1, seen)
                         end
            content = apply_delta(base, inflated, max)
            return {kind, content}
          end
          raise Git::Error.new("Git packed entry size mismatch") unless inflated.bytesize == size
          kind = case type_code
                 when 1 then "commit"
                 when 2 then "tree"
                 when 3 then "blob"
                 else        "tag"
                 end
          {kind, inflated}
        end
      rescue ex : IO::Error | Compress::Zlib::Error
        raise Git::Error.new("Git packed object invalid: #{ex.class}")
      end

      private def apply_delta(base : String, delta : String, max : Int32) : String
        source = IO::Memory.new(delta)
        original = delta_varint(source)
        target_size = delta_varint(source)
        raise Git::Error.new("Git delta base size mismatch") unless original == base.bytesize
        raise Git::Error.new("Git delta exceeds budget") if target_size > max
        output = IO::Memory.new
        until source.pos >= delta.bytesize
          opcode = source.read_byte || raise Git::Error.new("Git delta truncated")
          if (opcode & 0x80) != 0
            offset = 0_i64
            length = 0_i64
            4.times { |i| offset |= (source.read_byte || raise Git::Error.new("truncated Git delta offset")).to_i64 << (i * 8) if (opcode & (1 << i)) != 0 }
            3.times { |i| length |= (source.read_byte || raise Git::Error.new("truncated Git delta length")).to_i64 << (i * 8) if (opcode & (0x10 << i)) != 0 }
            length = 65_536_i64 if length == 0
            raise Git::Error.new("invalid Git delta copy") if offset + length > base.bytesize || output.size + length > target_size
            output.write(base.to_slice[offset.to_i, length.to_i])
          elsif opcode != 0
            raise Git::Error.new("invalid Git delta literal") if source.pos + opcode > delta.bytesize || output.size + opcode > target_size
            output.write(read_bytes_exact(source, opcode))
          else
            raise Git::Error.new("invalid Git delta opcode")
          end
        end
        raise Git::Error.new("Git delta output size mismatch") unless output.size == target_size
        output.to_s
      end

      private def delta_varint(io : IO) : Int64
        number = 0_i64
        shift = 0
        loop do
          byte = io.read_byte || raise Git::Error.new("truncated Git delta varint")
          raise Git::Error.new("Git delta length overflows") if shift > 42
          number |= (byte & 0x7f).to_i64 << shift
          return number if (byte & 0x80) == 0
          shift += 7
        end
      end

      private def read_bytes_exact(io : IO, size : Int32) : Bytes
        bytes = Bytes.new(size)
        io.read_fully(bytes)
        bytes
      end

      private def bounded_decompress(z : IO, max : Int32) : String
        target = IO::Memory.new
        IO.copy(z, target, max + 1)
        raise Git::Error.new("Git object exceeded size limit") if target.size > max
        target.to_s
      end
    end
  end
end
