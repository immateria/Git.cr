require "compress/zlib"
require "set"

module Git
  # Loose-object loading, object identity verification, and pack selection.
  # No HEAD/ref lookup, tree traversal, or worktree policy is owned here.
  class ObjectDatabase
    def initialize(@common : String, @object_format : ObjectId::Format)
      @pack_files = PackFiles.new(@common, @object_format)
    end

    # P17: publish a native loose object, without an agent/tool permission.
    # The data is raw bytes. Existing names are validated and never replaced.
    def write_blob(data : String | Bytes, *, max_bytes : Int64 = Int64::MAX,
                   &check : -> Nil) : String
      write_loose("blob", data.to_slice, max_bytes: max_bytes) { check.call }
    end

    # Structurally validated tree bodies are produced by Git::Tree.encode.
    # Object existence and referent-type checks are separate concerns.
    def write_tree(data : String | Bytes, *, max_bytes : Int64 = Int64::MAX,
                   &check : -> Nil) : String
      write_loose("tree", data.to_slice, max_bytes: max_bytes) { check.call }
    end

    # Typed, raw commit/tag objects use the same immutable publication protocol.
    def write_commit(data : String | Bytes, *, max_bytes : Int64 = Int64::MAX,
                     &check : -> Nil) : String
      write_loose("commit", data.to_slice, max_bytes: max_bytes) { check.call }
    end

    def write_tag(data : String | Bytes, *, max_bytes : Int64 = Int64::MAX,
                  &check : -> Nil) : String
      write_loose("tag", data.to_slice, max_bytes: max_bytes) { check.call }
    end

    private def write_loose(type : String, data : Bytes, *, max_bytes : Int64,
                            &check : -> Nil) : String
      raise ArgumentError.new("invalid Git #{type} write budget") if max_bytes < 0
      raise Error.new("Git #{type} write budget exceeded") if data.size.to_i64 > max_bytes || data.size > Int32::MAX - 128
      check.call
      objects = File.join(@common, "objects")
      require_object_directory!(objects)
      oid = ObjectId.digest(type, data, @object_format)
      fanout = File.join(objects, oid.byte_slice(0, 2))
      created_fanout = false
      begin
        unless Dir.exists?(fanout) || File.symlink?(fanout)
          Dir.mkdir(fanout, 0o755)
          created_fanout = true
        end
      rescue ex : File::AlreadyExistsError
        # Another cooperating writer may have created the fanout directory.
      end
      require_object_directory!(fanout)
      File.open(objects) { |directory| directory.fsync } if created_fanout
      final = File.join(fanout, oid.byte_slice(2, oid.bytesize - 2))
      if File.info?(final, follow_symlinks: false)
        verify_existing!(final, oid, type, data)
        check.call
        return oid
      end
      temp = File.join(fanout, "tmp_obj_#{Random::Secure.hex(16)}")
      fd = LibC.open(temp, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o444)
      raise Error.new("Git loose-object temporary file unavailable") if fd < 0
      begin
        io = IO::FileDescriptor.new(fd)
        begin
          Compress::Zlib::Writer.open(io) do |writer|
            writer.write("#{type} #{data.size}\0".to_slice)
            writer.write(data)
          end
          io.flush
          io.fsync
        ensure
          io.close
        end
        check.call
        require_object_directory!(objects)
        require_object_directory!(fanout)
        begin
          File.link(temp, final) # EEXIST is not replaced, even concurrently.
        rescue ex : File::AlreadyExistsError
          verify_existing!(final, oid, type, data)
        end
        File.open(fanout) { |directory| directory.fsync }
        check.call
        oid
      ensure
        File.delete?(temp)
      end
    rescue ex : File::Error | IO::Error | Compress::Zlib::Error
      raise Error.new("Git loose-object write failed: #{ex.class}")
    end

    private def require_object_directory!(path : String) : Nil
      raise Error.new("Git object directory missing or redirected") unless Dir.exists?(path) && !File.symlink?(path) && File.realpath(path) == path
    end

    private def verify_existing!(path : String, oid : String, type : String, data : Bytes) : Nil
      info = File.info?(path, follow_symlinks: false)
      raise Error.new("Git loose object target is not a regular file") unless info && info.type.file?
      raw = inflate_file(path, data.size + 128)
      marker = raw.index('\0')
      raise Error.new("Git existing loose object has invalid envelope") unless marker &&
                                                                               raw.byte_slice(0, marker) == "#{type} #{data.size}" &&
                                                                               raw.bytesize == marker + 1 + data.size &&
                                                                               raw.byte_slice(marker + 1, data.size).to_slice == data
      raise Error.new("Git existing loose object has invalid digest") unless ObjectId.digest(type, data, @object_format) == oid
    end

    def object(oid : String, max_bytes : Int32, depth : Int32 = 0, seen = Set(String).new, &check : -> Nil) : {String, String}
      raise Git::Error.new("Git object reference depth exceeded") if depth >= PackFiles::MAX_DELTA_DEPTH || seen.includes?(oid)
      seen.add(oid)
      ObjectId.valid!(oid, @object_format)
      check.call
      loose = File.join(@common, "objects", oid.byte_slice(0, 2), oid.byte_slice(2, @object_format.hexsize - 2))
      if File.file?(loose)
        data = inflate_file(loose, max_bytes + 128)
        sep = data.index('\0') || raise Git::Error.new("invalid loose Git object")
        header = data.byte_slice(0, sep)
        type, length = parse_object_header(header)
        content = data.byte_slice(sep + 1, data.bytesize - sep - 1)
        raise Git::Error.new("Git loose object size mismatch") unless content.bytesize == length
        verify_oid!(oid, type, content)
        return {type, content}
      end
      pack = @pack_files.find_packed(oid)
      raise Git::Error.new("Git object not available locally (no alternates/promisor support)") unless pack
      packfile, offset = pack
      resolver = ->(base_oid : String, next_depth : Int32, ancestors : Set(String)) do
        object(base_oid, max_bytes, next_depth, ancestors) { check.call }
      end
      type, content = @pack_files.decode_pack(packfile, offset, max_bytes, depth, seen, resolver) { check.call }
      verify_oid!(oid, type, content)
      {type, content}
    ensure
      seen.delete(oid)
    end

    # Type and size of an object from its stored headers, without
    # inflating or hashing its contents. Not verified against the ID.
    def object_header(oid : String, depth : Int32 = 0, &check : -> Nil) : {String, Int64}
      raise Git::Error.new("Git object reference depth exceeded") if depth >= PackFiles::MAX_DELTA_DEPTH
      ObjectId.valid!(oid, @object_format)
      check.call
      loose = File.join(@common, "objects", oid.byte_slice(0, 2), oid.byte_slice(2, @object_format.hexsize - 2))
      if File.file?(loose)
        raise Git::Error.new("Git object file redirected") if File.symlink?(loose)
        header = File.open(loose) do |file|
          Compress::Zlib::Reader.open(file) do |zlib|
            buffer = IO::Memory.new
            while (byte = zlib.read_byte) && byte != 0
              buffer.write_byte(byte)
              raise Git::Error.new("invalid loose Git object") if buffer.size > 64
            end
            buffer.to_s
          end
        end
        type, length = parse_object_header(header)
        return {type, length.to_i64}
      end
      location = @pack_files.locate(oid) || raise Git::Error.new("Git object not available locally (no alternates/promisor support)")
      resolver = ->(base : String) { object_header(base, depth + 1) { check.call }[0] }
      @pack_files.entry_info(location[0], location[1], resolver)
    rescue ex : Compress::Zlib::Error | IO::Error
      raise Git::Error.new("Git object header unreadable: #{ex.class}")
    end

    # Whether the object is stored loose or in a pack, without reading or
    # verifying its contents.
    def has_object?(oid : String) : Bool
      ObjectId.valid!(oid, @object_format)
      loose = File.join(@common, "objects", oid.byte_slice(0, 2), oid.byte_slice(2, @object_format.hexsize - 2))
      return true if File.file?(loose)
      @pack_files.contains?(oid)
    end

    # Every loose and packed object ID, each once, in no particular order.
    def each_oid(& : String ->) : Nil
      seen = Set(String).new
      objects = File.join(@common, "objects")
      if Dir.exists?(objects)
        Dir.each_child(objects) do |fanout|
          next unless fanout.bytesize == 2 && fanout.each_char.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) }
          directory = File.join(objects, fanout)
          next if File.symlink?(directory) || !Dir.exists?(directory)
          Dir.each_child(directory) do |rest|
            next unless rest.bytesize == @object_format.hexsize - 2 && rest.each_char.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) }
            oid = fanout + rest
            yield oid if seen.add?(oid)
          end
        end
      end
      @pack_files.each_oid { |oid| yield oid if seen.add?(oid) }
    end

    # The pack directory and its cached indexes.
    getter pack_files : PackFiles

    # Drop cached pack listings after a pack was added or removed.
    def refresh_packs : Nil
      @pack_files.refresh
    end

    private def parse_object_header(header : String) : {String, Int32}
      parts = header.split(' ', 2)
      raise Git::Error.new("invalid Git object header") unless parts.size == 2 && {"commit", "tree", "blob", "tag"}.includes?(parts[0])
      len = parts[1].to_i?
      raise Git::Error.new("invalid Git object length") unless len && len >= 0
      {parts[0], len}
    end

    private def verify_oid!(oid : String, type : String, data : String) : Nil
      raise Git::Error.new("Git object digest mismatch") unless ObjectId.digest(type, data, @object_format) == oid
    end

    private def inflate_file(path : String, max : Int32) : String
      raise Git::Error.new("Git object file redirected") if File.symlink?(path) || File.realpath(path) != path
      File.open(path) do |f|
        Compress::Zlib::Reader.open(f) { |z| bounded_decompress(z, max) }
      end
    rescue ex : Compress::Zlib::Error | IO::Error
      raise Git::Error.new("Git object decompression failed: #{ex.class}")
    end

    private def bounded_decompress(z : IO, max : Int32) : String
      target = IO::Memory.new
      IO.copy(z, target, max + 1)
      raise Git::Error.new("Git object exceeded size limit") if target.size > max
      target.to_s
    end
  end
end
