require "compress/zlib"

module Git
  module Pack
    # Git's index-pack: parse a pack, resolve every OFS_DELTA/REF_DELTA,
    # name each object and produce the .idx entries. Thin packs (REF_DELTA
    # bases outside the pack) are completed by appending the bases from a
    # caller-supplied object source, as `index-pack --fix-thin` does.
    class Indexer
      record Result, checksum : String, entries : Array(IndexEntry), appended : Int32,
        types : Hash(String, String)

      DEFAULT_MAX_OBJECT_BYTES = 2_147_483_646_i64

      private struct Parsed
        getter offset : Int64
        getter data_offset : Int64
        getter entry_type : EntryType
        getter size : Int64
        getter base_offset : Int64
        getter base_oid : String?
        property crc : UInt32
        property oid : String?
        property type : String?

        def initialize(@offset, @data_offset, @entry_type, @size, @base_offset, @base_oid, @crc, @oid, @type)
        end

        def delta? : Bool
          @entry_type.delta?
        end
      end

      # local_object returns an object this repository already has, or nil.
      # It completes thin packs (when fix_thin) and checks that any object
      # the pack shares with the repository has identical contents.
      def initialize(@format : ObjectId::Format, *,
                     @max_object_bytes : Int64 = DEFAULT_MAX_OBJECT_BYTES,
                     @max_objects : Int64 = 40_000_000,
                     @local_object : Proc(String, {String, String}?)? = nil,
                     @fix_thin : Bool = false,
                     @check_collisions : Bool = true,
                     @check : Proc(Nil)? = nil)
        raise ArgumentError.new("invalid Git pack indexing budgets") if @max_object_bytes < 1 || @max_objects < 1
      end

      # Read one whole pack from input, copying exactly its bytes to the new
      # file pack_path, then index it. Nothing past the trailer is consumed
      # from input beyond the reader's buffer.
      def index_stream(input : IO, pack_path : String) : Result
        File.open(pack_path, "wb+") do |file|
          reader = StreamReader.new(input, @format, tee: file)
          parsed = parse(reader)
          file.flush
          resolve(file, parsed)
        end
      end

      # Index an existing complete pack file; trailing bytes are an error.
      def index_file(pack_path : String) : Result
        File.open(pack_path, @fix_thin ? "rb+" : "rb") do |file|
          reader = StreamReader.new(file, @format)
          parsed = parse(reader)
          raise Git::Error.new("Git pack has junk at the end") unless reader.eof?
          resolve(file, parsed)
        end
      end

      private def parse(reader : StreamReader) : Array(Parsed)
        signature = reader.read_exact(4)
        raise Git::Error.new("Git pack signature missing") unless signature == SIGNATURE
        version = u32(reader.read_exact(4))
        raise Git::Error.new("unsupported Git pack version #{version}") unless version == 2 || version == 3
        count = u32(reader.read_exact(4)).to_i64
        raise Git::Error.new("Git pack object count exceeds budget") if count > @max_objects
        entries = Array(Parsed).new(count.to_i)
        by_offset = {} of Int64 => Int32
        count.times do
          @check.try &.call
          reader.begin_entry
          offset = reader.position
          byte = reader.read_byte || raise Git::Error.new("Git pack stream truncated")
          entry_type = EntryType.from_code(((byte >> 4) & 7).to_i32)
          size = (byte & 0x0f).to_i64
          shift = 4
          while (byte & 0x80) != 0
            byte = reader.read_byte || raise Git::Error.new("Git pack stream truncated")
            raise Git::Error.new("Git object size invalid") if shift > 56
            size |= (byte & 0x7f).to_i64 << shift
            shift += 7
          end
          base_offset = -1_i64
          base_oid = nil.as(String?)
          case entry_type
          when .ofs_delta?
            byte = reader.read_byte || raise Git::Error.new("Git pack stream truncated")
            distance = (byte & 0x7f).to_i64
            while (byte & 0x80) != 0
              byte = reader.read_byte || raise Git::Error.new("Git pack stream truncated")
              raise Git::Error.new("Git delta distance overflows") if distance >= (Int64::MAX >> 7) - 1
              distance = ((distance + 1) << 7) | (byte & 0x7f).to_i64
            end
            base_offset = offset - distance
            raise Git::Error.new("invalid Git delta base offset") unless distance > 0 && by_offset.has_key?(base_offset)
          when .ref_delta?
            base_oid = reader.read_exact(@format.bytesize).hexstring
          else
          end
          data_offset = reader.position
          data = reader.inflate(size, @max_object_bytes)
          oid = nil.as(String?)
          type = nil.as(String?)
          unless entry_type.delta?
            type = entry_type.object_type
            oid = ObjectId.digest(type, data, @format)
          end
          by_offset[offset] = entries.size
          entries << Parsed.new(offset, data_offset, entry_type, size, base_offset, base_oid,
            reader.crc, oid, type)
        end
        body = reader.body_checksum
        trailer = reader.read_trailer
        raise Git::Error.new("Git pack checksum mismatch") unless body == trailer
        entries
      end

      private def resolve(file : File, entries : Array(Parsed)) : Result
        ofs_children = {} of Int64 => Array(Int32)
        ref_children = {} of String => Array(Int32)
        entries.each_with_index do |entry, index|
          next unless entry.delta?
          if oid = entry.base_oid
            (ref_children[oid] ||= [] of Int32) << index
          else
            (ofs_children[entry.base_offset] ||= [] of Int32) << index
          end
        end
        types = {} of String => String
        entries.each_with_index do |entry, index|
          next if entry.delta?
          content = read_data(file, entry)
          note(types, entry.oid.not_nil!, entry.type.not_nil!, content)
          resolve_children(file, entries, index, entry.type.not_nil!, content, ofs_children, ref_children, types)
        end
        appended = 0
        unresolved = entries.count { |entry| entry.oid.nil? }
        if unresolved > 0
          missing = ref_children.keys.reject { |oid| types.has_key?(oid) }
          raise Git::Error.new("Git pack has #{unresolved} unresolved deltas") unless @fix_thin && (source = @local_object)
          bases = missing.map do |oid|
            found = source.call(oid) || raise Git::Error.new("Git thin pack base #{oid} is missing locally")
            {oid, found[0], found[1]}
          end
          appended_entries = append_bases(file, entries.size, bases)
          bases.each_with_index do |(oid, type, content), position|
            entries << appended_entries[position]
            note(types, oid, type, content, local: true)
            resolve_children(file, entries, entries.size - 1, type, content, ofs_children, ref_children, types)
          end
          appended = bases.size
          remaining = entries.count { |entry| entry.oid.nil? }
          raise Git::Error.new("Git pack has #{remaining} unresolved deltas") unless remaining == 0
        end
        checksum = finish_checksum(file, appended > 0)
        result = entries.map { |entry| IndexEntry.new(entry.oid.not_nil!, entry.offset, entry.crc) }
        Result.new(checksum.hexstring, result, appended, types)
      end

      private def resolve_children(file : File, entries : Array(Parsed), root : Int32, type : String,
                                   content : String, ofs_children : Hash(Int64, Array(Int32)),
                                   ref_children : Hash(String, Array(Int32)),
                                   types : Hash(String, String)) : Nil
        # Pending children carry their base's content; siblings share it.
        stack = [] of {Int32, String, String}
        push_children(entries[root], content, type, ofs_children, ref_children, stack)
        until stack.empty?
          @check.try &.call
          index, base_type, base = stack.pop
          entry = entries[index]
          next if entry.oid
          delta = read_data(file, entry)
          result = Delta.apply(base, delta, @max_object_bytes)
          oid = ObjectId.digest(base_type, result, @format)
          entry.oid = oid
          entry.type = base_type
          entries[index] = entry
          note(types, oid, base_type, result)
          push_children(entry, result, base_type, ofs_children, ref_children, stack)
        end
      end

      private def push_children(entry : Parsed, content : String, type : String,
                                ofs_children : Hash(Int64, Array(Int32)),
                                ref_children : Hash(String, Array(Int32)),
                                stack : Array({Int32, String, String})) : Nil
        ofs_children[entry.offset]?.try &.each { |child| stack << {child, type, content} }
        entry.oid.try { |oid| ref_children[oid]?.try &.each { |child| stack << {child, type, content} } }
      end

      private def note(types : Hash(String, String), oid : String, type : String, content : String,
                       local : Bool = false) : Nil
        raise Git::Error.new("Git pack contains duplicate object #{oid}") if types.has_key?(oid)
        types[oid] = type
        return if local || !@check_collisions
        if source = @local_object
          if existing = source.call(oid)
            unless existing[0] == type && existing[1] == content
              raise Git::Error.new("Git object collision for #{oid}")
            end
          end
        end
      end

      private def read_data(file : File, entry : Parsed) : String
        file.seek(entry.data_offset)
        Compress::Zlib::Reader.open(file) do |zlib|
          buffer = IO::Memory.new
          IO.copy(zlib, buffer, entry.size + 1)
          raise Git::Error.new("Git packed entry size mismatch") unless buffer.size == entry.size
          buffer.to_s
        end
      rescue ex : Compress::Zlib::Error | IO::Error
        raise Git::Error.new("Git packed entry invalid: #{ex.class}")
      end

      # Replace the trailer with appended base entries, fix the header
      # count, and leave the file ready for a new trailer.
      private def append_bases(file : File, existing : Int32, bases : Array({String, String, String})) : Array(Parsed)
        file.flush
        body_end = file.size - @format.bytesize
        file.truncate(body_end)
        file.seek(body_end)
        appended = [] of Parsed
        bases.each do |(oid, type, content)|
          offset = file.pos.to_i64
          entry_type = EntryType.for_object(type)
          size = content.bytesize.to_i64
          header = EntryHeader.encode(entry_type, size)
          compressed = IO::Memory.new
          Compress::Zlib::Writer.open(compressed) { |zlib| zlib.write(content.to_slice) }
          crc = Digest::CRC32.update(header, Digest::CRC32.initial)
          crc = Digest::CRC32.update(compressed.to_slice, crc)
          data_offset = offset + header.size
          file.write(header)
          file.write(compressed.to_slice)
          appended << Parsed.new(offset, data_offset, entry_type, size, -1_i64, nil, crc, oid, type)
        end
        file.seek(8)
        file.write_bytes((existing + bases.size).to_u32, IO::ByteFormat::BigEndian)
        file.flush
        appended
      end

      # The pack checksum: the verified trailer, or a new one after thin
      # bases were appended.
      private def finish_checksum(file : File, rewritten : Bool) : Bytes
        if rewritten
          file.flush
          file.seek(0)
          checksum = Checksum.new(@format)
          buffer = Bytes.new(65_536)
          while (read = file.read(buffer)) > 0
            checksum.update(buffer[0, read])
          end
          digest = checksum.final
          file.seek(0, IO::Seek::End)
          file.write(digest)
          file.flush
          digest
        else
          file.seek(file.size - @format.bytesize)
          digest = Bytes.new(@format.bytesize)
          file.read_fully(digest)
          digest
        end
      end

      private def u32(bytes : Bytes) : UInt32
        (bytes[0].to_u32 << 24) | (bytes[1].to_u32 << 16) | (bytes[2].to_u32 << 8) | bytes[3].to_u32
      end
    end
  end
end
