require "compress/zlib"
require "digest/crc32"
require "set"

module Git
  # Pack index v2 lookup and compressed delta reconstruction. The only
  # caller supplies an object-ID resolver for REF_DELTA parents that live
  # outside the pack being read.
  class ObjectDatabase
    class PackFiles
      MAX_PACKS              =         4_096
      MAX_INDEX_BYTES        = 1_073_741_824
      MAX_INDEX_OBJECTS      =    40_000_000
      MAX_PACKED_ENTRY_BYTES = 2_147_483_647_i64
      # Git writes chains of at most 4095 deltas (pack-objects caps --depth);
      # resolution is iterative, so this only bounds hostile input.
      MAX_DELTA_DEPTH = 10_000
      # Recently reconstructed delta bases, as in Git's delta_base_cache.
      DELTA_BASE_CACHE_BYTES = 33_554_432

      # A pack index whose layout, checksum and pack pairing were verified
      # when it was loaded. Pack and index files are immutable once Git
      # publishes them (their names are content checksums); a changed file
      # identity forces a reload and full revalidation.
      private class IndexFile
        getter path : String
        getter pack_path : String
        getter count : Int64
        getter raw : Bytes
        getter pack_end : Int64
        getter sorted_offsets : Array(Int64)
        getter idx_info : File::Info
        getter pack_info : File::Info

        def initialize(@path, @pack_path, @count, @raw, @pack_end, @sorted_offsets,
                       @idx_info, @pack_info, @hash_size : Int32, @large_start : Int64)
        end

        def table_start : Int64
          8_i64 + 1024
        end

        def fanout(index : Int32) : Int64
          position = 8 + index * 4
          ((@raw[position].to_u32 << 24) | (@raw[position + 1].to_u32 << 16) |
            (@raw[position + 2].to_u32 << 8) | @raw[position + 3].to_u32).to_i64
        end

        def oid_at(row : Int64) : Bytes
          @raw[(table_start + row * @hash_size).to_i, @hash_size]
        end

        def crc_at(row : Int64) : UInt32
          read_u32((table_start + @count * @hash_size + row * 4).to_i)
        end

        def offset_at(row : Int64) : Int64
          encoded = read_u32((table_start + @count * (@hash_size + 4) + row * 4).to_i)
          return encoded.to_i64 if (encoded & 0x8000_0000_u32) == 0
          entry = (encoded & 0x7fff_ffff_u32).to_i64
          position = (@large_start + entry * 8).to_i
          high = read_u32(position).to_u64
          low = read_u32(position + 4).to_u64
          ((high << 32) | low).to_i64
        end

        def lookup(wanted : Bytes) : Int64?
          first = wanted[0].to_i
          low = first.zero? ? 0_i64 : fanout(first - 1)
          high = fanout(first)
          while low < high
            mid = low + (high - low) // 2
            comparison = oid_at(mid) <=> wanted
            return mid if comparison == 0
            if comparison < 0
              low = mid + 1
            else
              high = mid
            end
          end
          nil
        end

        # Object IDs starting with the hex prefix (even-length bytes plus an
        # optional high nibble), in sorted order.
        def each_prefix_match(prefix : String, & : String ->) : Nil
          return if prefix.empty?
          first = prefix.byte_slice(0, 2).ljust(2, '0').to_i(16)
          low = first.zero? ? 0_i64 : fanout(first - 1)
          high = fanout(first)
          wanted = prefix.ljust(@hash_size * 2, '0').hexbytes
          # Lower bound of the zero-padded prefix.
          while low < high
            mid = low + (high - low) // 2
            if (oid_at(mid) <=> wanted) < 0
              low = mid + 1
            else
              high = mid
            end
          end
          row = low
          while row < @count
            hex = oid_at(row).hexstring
            break unless hex.starts_with?(prefix)
            yield hex
            row += 1
          end
        end

        @rows_by_offset : Hash(Int64, Int64)? = nil

        # The object ID stored at an entry offset.
        def oid_at_offset(offset : Int64) : String?
          rows = @rows_by_offset ||= begin
            map = Hash(Int64, Int64).new(initial_capacity: @count.to_i)
            @count.times { |row| map[offset_at(row)] = row }
            map
          end
          rows[offset]?.try { |row| oid_at(row).hexstring }
        end

        # The first byte after the entry at offset: the next entry's start or
        # the pack trailer.
        def entry_end(offset : Int64) : Int64
          index = @sorted_offsets.bsearch_index { |value| value > offset }
          index ? @sorted_offsets[index] : @pack_end
        end

        private def read_u32(position : Int32) : UInt32
          (@raw[position].to_u32 << 24) | (@raw[position + 1].to_u32 << 16) |
            (@raw[position + 2].to_u32 << 8) | @raw[position + 3].to_u32
        end
      end

      @indexes = {} of String => IndexFile
      @listing : Array(String)? = nil
      @listing_info : File::Info? = nil
      @base_cache = {} of {String, Int64} => {String, String}
      @base_cache_bytes = 0_i64
      @mutex = Mutex.new

      getter max_delta_depth : Int32

      def initialize(@common : String, @object_format : ObjectId::Format, *,
                     @max_delta_depth : Int32 = MAX_DELTA_DEPTH)
        raise ArgumentError.new("invalid Git delta depth budget") if @max_delta_depth < 1
        @pack_filename = Regex.new("\\Apack-[0-9a-f]{#{@object_format.hexsize}}\\.idx\\z")
      end

      def directory : String
        File.join(@common, "objects", "pack")
      end

      def find_packed(oid : String) : {String, Int64}?
        wanted = oid.hexbytes
        index_paths.each do |idx_path|
          index = load_index(idx_path) || next
          if row = index.lookup(wanted)
            return {index.pack_path, verified_offset(index, row)}
          end
        end
        nil
      end

      # The pack and offset of an object without verifying its entry CRC.
      def locate(oid : String) : {String, Int64}?
        wanted = oid.hexbytes
        index_paths.each do |idx_path|
          index = load_index(idx_path) || next
          if row = index.lookup(wanted)
            return {index.pack_path, index.offset_at(row)}
          end
        end
        nil
      end

      # Type and inflated size of the object at offset, from entry headers
      # and delta headers only. base_type names REF_DELTA bases in other
      # packs. The result is not verified against the object ID.
      def entry_info(file : String, offset : Int64, base_type : Proc(String, String)) : {String, Int64}
        index = @mutex.synchronize { @indexes.values.find { |candidate| candidate.pack_path == file } }
        File.open(file) do |io|
          size = nil.as(Int64?)
          current = offset
          hops = 0
          loop do
            raise Git::Error.new("Git pack offset out of bounds") unless current >= 12 && current < io.size - @object_format.bytesize
            io.seek(current)
            header = PackFiles.read_entry_header(io, current, @object_format.bytesize)
            return {PackFiles.type_name(header.type_code), size || header.size} if header.type_code < 6
            if size.nil?
              io.seek(header.data_offset)
              prefix = Compress::Zlib::Reader.open(io) do |zlib|
                buffer = IO::Memory.new
                IO.copy(zlib, buffer, 20)
                buffer.to_slice
              end
              position = 0
              2.times do |field|
                value = 0_i64
                shift = 0
                loop do
                  raise Git::Error.new("truncated Git delta header") if position >= prefix.size || shift > 56
                  byte = prefix[position]
                  position += 1
                  value |= (byte & 0x7f).to_i64 << shift
                  shift += 7
                  break if (byte & 0x80) == 0
                end
                size = value if field == 1
              end
            end
            hops += 1
            raise Git::Error.new("Git delta chain too deep") if hops >= @max_delta_depth
            if base_offset = header.base_offset
              current = base_offset
            else
              base_oid = header.base_oid.not_nil!
              if index && (row = index.lookup(base_oid.hexbytes))
                current = index.offset_at(row)
              else
                return {base_type.call(base_oid), size.not_nil!}
              end
            end
          end
        end
      rescue ex : IO::Error | Compress::Zlib::Error
        raise Git::Error.new("Git packed object header invalid: #{ex.class}")
      end

      # A stored pack entry that can be copied into another pack: its header,
      # its delta base by object ID (for OFS_DELTA too) and the bounds of
      # its compressed data. The entry CRC has been verified.
      record RawEntry, pack_path : String, offset : Int64, finish : Int64,
        header : EntryHeader, base_oid : String?

      def raw_entry(oid : String) : RawEntry?
        wanted = oid.hexbytes
        index_paths.each do |idx_path|
          index = load_index(idx_path) || next
          row = index.lookup(wanted) || next
          offset = verified_offset(index, row)
          finish = index.entry_end(offset)
          header = File.open(index.pack_path) do |io|
            io.seek(offset)
            PackFiles.read_entry_header(io, offset, @object_format.bytesize)
          end
          base = header.base_oid
          if base_offset = header.base_offset
            base = index.oid_at_offset(base_offset) || return nil
          end
          return RawEntry.new(index.pack_path, offset, finish, header, base)
        end
        nil
      rescue ex : IO::Error
        raise Git::Error.new("Git pack entry unreadable: #{ex.class}")
      end

      # The compressed bytes of a raw entry (after its header).
      def raw_data(entry : RawEntry) : Bytes
        File.open(entry.pack_path) do |io|
          io.seek(entry.header.data_offset)
          bytes = Bytes.new((entry.finish - entry.header.data_offset).to_i)
          io.read_fully(bytes)
          bytes
        end
      end

      # Packed object IDs that start with a lowercase hex prefix.
      def prefix_matches(prefix : String, limit : Int32 = 16) : Array(String)
        found = [] of String
        index_paths.each do |idx_path|
          index = load_index(idx_path) || next
          index.each_prefix_match(prefix) do |oid|
            found << oid unless found.includes?(oid)
            return found if found.size >= limit
          end
        end
        found
      end

      # Whether some pack index lists the object; nothing is read from the
      # pack itself.
      def contains?(oid : String) : Bool
        wanted = oid.hexbytes
        index_paths.any? { |idx_path| load_index(idx_path).try(&.lookup(wanted)) }
      end

      # Every object ID in every readable pack, in pack-name then ID order.
      # Duplicates across packs are reported once.
      def each_oid(& : String ->) : Nil
        seen = Set(String).new
        index_paths.each do |idx_path|
          index = load_index(idx_path) || next
          index.count.times do |row|
            oid = index.oid_at(row).hexstring
            yield oid if seen.add?(oid)
          end
        end
      end

      # Forget every cached index so that later lookups see packs written
      # by this process or another writer.
      def refresh : Nil
        @mutex.synchronize do
          @listing = nil
          @listing_info = nil
        end
      end

      private def index_paths : Array(String)
        directory = self.directory
        info = File.info?(directory, follow_symlinks: false)
        return [] of String unless info
        raise Git::Error.new("Git pack directory redirected") unless info.directory?
        @mutex.synchronize do
          cached = @listing
          previous = @listing_info
          if cached && previous && previous.same_file?(info) && previous.modification_time == info.modification_time
            return cached
          end
          raise Git::Error.new("Git pack directory redirected") unless File.realpath(directory) == directory
          names = [] of String
          Dir.each_child(directory) do |entry|
            next unless entry.matches?(@pack_filename)
            names << entry
            raise Git::Error.new("Git pack file count exceeded") if names.size > MAX_PACKS
          end
          paths = names.sort!.map { |name| File.join(directory, name) }
          @listing = paths
          @listing_info = info
          @indexes.select! { |path, _| paths.includes?(path) }
          paths
        end
      end

      private def load_index(idx_path : String) : IndexFile?
        pack_path = idx_path.sub(/\.idx\z/, ".pack")
        idx_info = File.info?(idx_path, follow_symlinks: false)
        pack_info = File.info?(pack_path, follow_symlinks: false)
        return nil unless pack_info && pack_info.file?
        raise Git::Error.new("Git pack index redirected") unless idx_info && idx_info.file?
        @mutex.synchronize do
          if cached = @indexes[idx_path]?
            return cached if same_identity?(cached.idx_info, idx_info) && same_identity?(cached.pack_info, pack_info)
          end
        end
        loaded = read_index(idx_path, pack_path)
        @mutex.synchronize { @indexes[idx_path] = loaded }
        loaded
      end

      private def same_identity?(left : File::Info, right : File::Info) : Bool
        left.same_file?(right) && left.size == right.size && left.modification_time == right.modification_time
      end

      # Index layout and repository-format checksum are verified before any
      # offset is trusted, once per file identity.
      private def read_index(idx : String, pack : String) : IndexFile
        raise Git::Error.new("Git pack index redirected") if File.symlink?(idx) || File.realpath(idx) != idx
        raise Git::Error.new("Git pack redirected") if File.symlink?(pack) || File.realpath(pack) != pack
        raw = File.open(idx) do |io|
          size = io.size
          raise Git::Error.new("Git pack index byte budget exceeded") if size > MAX_INDEX_BYTES
          bytes = Bytes.new(size)
          io.read_fully(bytes)
          raise Git::Error.new("Git pack index changed while reading") unless io.read_byte.nil?
          bytes
        end
        hash_size = @object_format.bytesize
        raise Git::Error.new("Git pack index truncated") if raw.size < 8 + 1024 + 2 * hash_size
        body_size = raw.size - hash_size
        raise Git::Error.new("Git pack index checksum mismatch") unless checksum(raw[0, body_size]) == raw[body_size, hash_size]
        raise Git::Error.new("Git pack index v2 required") unless raw[0, 4].hexstring == "ff744f63" &&
                                                                  raw[4, 4].hexstring == "00000002"
        previous = 0_i64
        fanout = Array(Int64).new(256) do |i|
          position = 8 + i * 4
          value = ((raw[position].to_u32 << 24) | (raw[position + 1].to_u32 << 16) |
                   (raw[position + 2].to_u32 << 8) | raw[position + 3].to_u32).to_i64
          raise Git::Error.new("Git pack fanout invalid") if value < previous
          previous = value
          value
        end
        total = fanout.last
        raise Git::Error.new("Git pack index count exceeds budget") if total > MAX_INDEX_OBJECTS || total == 0
        table = 8_i64 + 1024
        large_start = table + total * (hash_size + 8)
        raise Git::Error.new("Git pack index tables truncated") if large_start + 2 * hash_size > raw.size
        extra = raw.size.to_i64 - large_start - 2 * hash_size
        raise Git::Error.new("Git pack index large-offset table invalid") unless extra % 8 == 0 && extra // 8 <= total
        large_count = extra // 8

        # The fanout and sorted ID table must agree even if an attacker
        # recomputes the index checksum after changing the metadata.
        counts = Array(Int64).new(256, 0_i64)
        prior = nil.as(Bytes?)
        total.times do |row|
          position = (table + row * hash_size).to_i
          current = raw[position, hash_size]
          raise Git::Error.new("Git pack object IDs out of order") if prior && (prior <=> current) >= 0
          counts[raw[position].to_i] += 1
          prior = current
        end
        cumulative = 0_i64
        256.times do |i|
          cumulative += counts[i]
          raise Git::Error.new("Git pack fanout does not match IDs") unless cumulative == fanout[i]
        end

        pack_checksum = raw[raw.size - 2 * hash_size, hash_size]
        pack_end = verify_pack_link!(pack, total, pack_checksum)
        offset_table = table + total * (hash_size + 4)
        offsets = Array(Int64).new(total.to_i) do |row|
          position = (offset_table + row * 4).to_i
          encoded = (raw[position].to_u32 << 24) | (raw[position + 1].to_u32 << 16) |
                    (raw[position + 2].to_u32 << 8) | raw[position + 3].to_u32
          offset = if (encoded & 0x8000_0000_u32) == 0
                     encoded.to_i64
                   else
                     entry = (encoded & 0x7fff_ffff_u32).to_i64
                     raise Git::Error.new("Git pack large-offset reference invalid") if entry >= large_count
                     large = (large_start + entry * 8).to_i
                     huge = (raw[large].to_u64 << 56) | (raw[large + 1].to_u64 << 48) |
                            (raw[large + 2].to_u64 << 40) | (raw[large + 3].to_u64 << 32) |
                            (raw[large + 4].to_u64 << 24) | (raw[large + 5].to_u64 << 16) |
                            (raw[large + 6].to_u64 << 8) | raw[large + 7].to_u64
                     raise Git::Error.new("Git pack large offset exceeds integer range") if huge > Int64::MAX.to_u64
                     huge.to_i64
                   end
          raise Git::Error.new("Git pack offset out of bounds") unless offset >= 12 && offset < pack_end
          offset
        end
        sorted = offsets.sort!
        (1...sorted.size).each do |i|
          raise Git::Error.new("Git pack offsets duplicate") if sorted[i] == sorted[i - 1]
        end
        idx_info = File.info(idx, follow_symlinks: false)
        pack_info = File.info(pack, follow_symlinks: false)
        IndexFile.new(idx, pack, total, raw, pack_end, sorted, idx_info, pack_info,
          hash_size, large_start)
      rescue ex : IO::Error | File::Error
        raise Git::Error.new("Git pack index I/O invalid: #{ex.class}")
      end

      # Revalidate the files that hold a hit before using the cached offset,
      # then check the entry's CRC32 against the index.
      private def verified_offset(index : IndexFile, row : Int64) : Int64
        idx_info = File.info?(index.path, follow_symlinks: false)
        pack_info = File.info?(index.pack_path, follow_symlinks: false)
        unless idx_info && pack_info && same_identity?(index.idx_info, idx_info) && same_identity?(index.pack_info, pack_info)
          raise Git::Error.new("Git pack changed during lookup")
        end
        offset = index.offset_at(row)
        verify_packed_crc!(index.pack_path, offset, index.entry_end(offset), index.crc_at(row))
        offset
      end

      # Git index CRC32 covers the full packed entry, from its type/size
      # header through its compressed bytes (not the expanded object).
      private def verify_packed_crc!(pack : String, start : Int64, finish : Int64, expected : UInt32) : Nil
        length = finish - start
        raise Git::Error.new("Git packed entry byte budget exceeded") if length <= 0 || length > MAX_PACKED_ENTRY_BYTES
        crc = Digest::CRC32.initial
        File.open(pack) do |io|
          io.seek(start)
          buffer = Bytes.new(length < 65_536 ? length.to_i : 65_536)
          remaining = length
          while remaining > 0
            part = remaining < buffer.size ? remaining.to_i : buffer.size
            chunk = buffer[0, part]
            io.read_fully(chunk)
            crc = Digest::CRC32.update(chunk, crc)
            remaining -= part
          end
        end
        raise Git::Error.new("Git packed object CRC mismatch") unless crc == expected
      rescue ex : IO::Error
        raise Git::Error.new("Git packed object I/O invalid: #{ex.class}")
      end

      # Pair the index with precisely the pack it describes, not merely a
      # similarly-named file. Each object read from it is independently
      # SHA-1/SHA-256 verified by Git::ObjectDatabase; this does not hash an
      # entire multi-GB pack.
      private def verify_pack_link!(pack : String, indexed_count : Int64, checksum : Bytes) : Int64
        File.open(pack) do |io|
          raise Git::Error.new("Git pack truncated") if io.size < 12 + @object_format.bytesize
          raise Git::Error.new("unsupported Git pack") unless read_bytes_exact(io, 4).hexstring == "5041434b"
          version = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("unsupported Git pack version") unless {2_u32, 3_u32}.includes?(version)
          count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("Git pack object count differs from index") unless count.to_i64 == indexed_count
          io.seek(io.size - @object_format.bytesize)
          raise Git::Error.new("Git pack checksum differs from index") unless read_bytes_exact(io, @object_format.bytesize) == checksum
          io.size - @object_format.bytesize
        end
      end

      private def checksum(data : Bytes) : Bytes
        case @object_format
        in .sha1?   then Digest::SHA1.digest(data).to_slice
        in .sha256? then Digest::SHA256.digest(data).to_slice
        end
      end

      # Header of a pack entry: type code, declared size, and the delta base
      # (an absolute offset for OFS_DELTA or an object ID for REF_DELTA).
      record EntryHeader, type_code : Int32, size : Int64, base_offset : Int64?, base_oid : String?, data_offset : Int64

      def self.read_entry_header(io : IO, offset : Int64, hash_size : Int32) : EntryHeader
        b = io.read_byte || raise Git::Error.new("truncated Git pack object")
        size = (b & 0x0f).to_i64
        type_code = ((b >> 4) & 7).to_i32
        shift = 4
        consumed = 1_i64
        while (b & 0x80) != 0
          b = io.read_byte || raise Git::Error.new("truncated Git object size")
          consumed += 1
          raise Git::Error.new("Git object size invalid") if shift > 56
          size |= (b & 0x7f).to_i64 << shift
          shift += 7
        end
        base_offset = nil.as(Int64?)
        base_oid = nil.as(String?)
        if type_code == 6
          byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
          consumed += 1
          distance = (byte & 0x7f).to_i64
          while (byte & 0x80) != 0
            byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
            consumed += 1
            raise Git::Error.new("Git delta distance overflows") if distance >= (Int64::MAX >> 7) - 1
            distance = ((distance + 1) << 7) | (byte & 0x7f).to_i64
            raise Git::Error.new("invalid Git delta distance") if distance >= offset
          end
          raise Git::Error.new("invalid Git delta parent offset") if distance <= 0 || offset - distance < 12
          base_offset = offset - distance
        elsif type_code == 7
          bytes = Bytes.new(hash_size)
          io.read_fully(bytes)
          consumed += hash_size
          base_oid = bytes.hexstring
        elsif !{1, 2, 3, 4}.includes?(type_code)
          raise Git::Error.new("unsupported Git pack entry type")
        end
        EntryHeader.new(type_code, size, base_offset, base_oid, offset + consumed)
      end

      def self.type_name(code : Int32) : String
        case code
        when 1 then "commit"
        when 2 then "tree"
        when 3 then "blob"
        when 4 then "tag"
        else        raise Git::Error.new("unsupported Git pack entry type")
        end
      end

      def self.type_code(name : String) : Int32
        case name
        when "commit" then 1
        when "tree"   then 2
        when "blob"   then 3
        when "tag"    then 4
        else               raise Git::Error.new("unsupported Git object type")
        end
      end

      # Reconstruct the object at offset. OFS_DELTA chains and REF_DELTA
      # bases found in the same pack are followed iteratively; other
      # REF_DELTA bases are delegated to resolve_oid.
      def decode_pack(file : String, offset : Int64, max : Int32, depth : Int32, seen : Set(String), resolve_oid : Proc(String, Int32, Set(String), {String, String}), &check : -> Nil) : {String, String}
        raise Git::Error.new("Git delta chain too deep") if depth >= @max_delta_depth
        index = @mutex.synchronize { @indexes.values.find { |candidate| candidate.pack_path == file } }
        # A pack reached through a verified index had its path checked when
        # the index was loaded and its identity on this lookup.
        unless index
          raise Git::Error.new("Git pack redirected") if File.symlink?(file) || File.realpath(file) != file
        end
        File.open(file) do |io|
          raise Git::Error.new("unsupported Git pack") unless read_bytes_exact(io, 4).hexstring == "5041434b"
          ver = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("unsupported Git pack version") unless {2_u32, 3_u32}.includes?(ver)
          count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          raise Git::Error.new("Git pack has no objects") if count == 0
          limit = io.size - @object_format.bytesize
          chain = [] of {Int64, String}
          current = offset
          base = nil.as({String, String}?)
          visited = Set(Int64).new
          loop do
            check.call
            raise Git::Error.new("Git pack offset out of bounds") unless current >= 12 && current < limit
            raise Git::Error.new("Git delta chain cycle") unless visited.add?(current)
            if cached = cached_base(file, current)
              base = cached
              break
            end
            raise Git::Error.new("Git delta chain too deep") if depth + chain.size >= @max_delta_depth
            io.seek(current)
            header = PackFiles.read_entry_header(io, current, @object_format.bytesize)
            raise Git::Error.new("Git object exceeds byte budget") if header.size > max
            inflated = Compress::Zlib::Reader.open(io) { |z| bounded_decompress(z, max + 128) }
            if header.type_code == 6 || header.type_code == 7
              raise Git::Error.new("Git packed delta instruction size mismatch") unless inflated.bytesize == header.size
              chain << {current, inflated}
              if base_offset = header.base_offset
                current = base_offset
                next
              end
              base_oid = header.base_oid.not_nil!
              if index && (row = index.lookup(base_oid.hexbytes))
                current = verified_offset(index, row)
                next
              end
              base = resolve_oid.call(base_oid, depth + chain.size, seen)
              break
            end
            raise Git::Error.new("Git packed entry size mismatch") unless inflated.bytesize == header.size
            base = {PackFiles.type_name(header.type_code), inflated}
            store_base(file, current, base) unless chain.empty?
            break
          end
          result = base.not_nil!
          chain.reverse_each.with_index do |(entry_offset, delta), position|
            check.call
            result = {result[0], apply_delta(result[1], delta, max)}
            store_base(file, entry_offset, result) if position < chain.size - 1
          end
          result
        end
      rescue ex : IO::Error | Compress::Zlib::Error
        raise Git::Error.new("Git packed object invalid: #{ex.class}")
      end

      private def cached_base(file : String, offset : Int64) : {String, String}?
        @mutex.synchronize do
          key = {file, offset}
          value = @base_cache.delete(key)
          @base_cache[key] = value if value
          value
        end
      end

      private def store_base(file : String, offset : Int64, value : {String, String}) : Nil
        size = value[1].bytesize.to_i64
        return if size > DELTA_BASE_CACHE_BYTES // 4
        @mutex.synchronize do
          key = {file, offset}
          if previous = @base_cache.delete(key)
            @base_cache_bytes -= previous[1].bytesize
          end
          @base_cache[key] = value
          @base_cache_bytes += size
          while @base_cache_bytes > DELTA_BASE_CACHE_BYTES && (oldest = @base_cache.first_key?)
            removed = @base_cache.delete(oldest).not_nil!
            @base_cache_bytes -= removed[1].bytesize
          end
        end
      end

      def self.apply_delta(base : String, delta : String, max : Int64) : String
        source = delta.to_slice
        position = 0
        original, position = delta_varint(source, position)
        target_size, position = delta_varint(source, position)
        raise Git::Error.new("Git delta base size mismatch") unless original == base.bytesize
        raise Git::Error.new("Git delta exceeds budget") if target_size > max
        base_bytes = base.to_slice
        String.new(target_size.to_i) do |buffer|
          written = 0
          while position < source.size
            opcode = source[position]
            position += 1
            if (opcode & 0x80) != 0
              copy_offset = 0_i64
              length = 0_i64
              4.times do |i|
                next if (opcode & (1 << i)) == 0
                raise Git::Error.new("truncated Git delta offset") if position >= source.size
                copy_offset |= source[position].to_i64 << (i * 8)
                position += 1
              end
              3.times do |i|
                next if (opcode & (0x10 << i)) == 0
                raise Git::Error.new("truncated Git delta length") if position >= source.size
                length |= source[position].to_i64 << (i * 8)
                position += 1
              end
              length = 65_536_i64 if length == 0
              raise Git::Error.new("invalid Git delta copy") if copy_offset + length > base_bytes.size || written + length > target_size
              (buffer + written).copy_from(base_bytes.to_unsafe + copy_offset, length)
              written += length.to_i
            elsif opcode != 0
              raise Git::Error.new("invalid Git delta literal") if position + opcode > source.size || written + opcode > target_size
              (buffer + written).copy_from(source.to_unsafe + position, opcode)
              written += opcode
              position += opcode
            else
              raise Git::Error.new("invalid Git delta opcode")
            end
          end
          raise Git::Error.new("Git delta output size mismatch") unless written == target_size
          {target_size.to_i, 0}
        end
      end

      private def apply_delta(base : String, delta : String, max : Int32) : String
        PackFiles.apply_delta(base, delta, max.to_i64)
      end

      private def self.delta_varint(source : Bytes, position : Int32) : {Int64, Int32}
        number = 0_i64
        shift = 0
        loop do
          raise Git::Error.new("truncated Git delta varint") if position >= source.size
          byte = source[position]
          position += 1
          raise Git::Error.new("Git delta length overflows") if shift > 42
          number |= (byte & 0x7f).to_i64 << shift
          return {number, position} if (byte & 0x80) == 0
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
