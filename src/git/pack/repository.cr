module Git
  module Pack
    # A pack index_pack published into objects/pack (nil paths when the
    # pack held no objects).
    record Published, checksum : String?, pack_path : String?, index_path : String?,
      entries : Array(IndexEntry), appended_bases : Int32, keep_path : String? do
      def object_count : Int32
        entries.size
      end
    end

    # Write the .idx (and .rev) for an existing pack file, as
    # `git index-pack <file>.pack` does. Returns the pack checksum.
    def self.index_file(pack_path : String, format : ObjectId::Format, *,
                        write_rev : Bool = true,
                        max_object_bytes : Int64 = Indexer::DEFAULT_MAX_OBJECT_BYTES,
                        check : Proc(Nil)? = nil) : Indexer::Result
      raise Git::Error.new("Git pack file name must end in .pack") unless pack_path.ends_with?(".pack")
      result = Indexer.new(format, max_object_bytes: max_object_bytes, check: check).index_file(pack_path)
      checksum = result.checksum.hexbytes
      stem = pack_path.byte_slice(0, pack_path.bytesize - 5)
      File.write(stem + ".idx", IndexFile.encode(result.entries, checksum, format))
      File.write(stem + ".rev", ReverseIndexFile.encode(result.entries, checksum, format)) if write_rev
      result
    end
  end

  class Repository
    # Store one pack stream in objects/pack (Git's `index-pack --stdin`).
    # Every delta is resolved and every object named before anything is
    # published; shared objects must match the local copies.
    # With fix_thin, REF_DELTA bases outside the pack are appended from
    # this repository. The .pack, .rev and optional .keep are published
    # before the .idx that makes the pack visible; existing files are never
    # replaced. The objects are not yet referenced by any ref.
    def index_pack(input : IO, *, fix_thin : Bool = true, keep : String? = nil,
                   write_rev : Bool = true, check_collisions : Bool = true,
                   max_object_bytes : Int64 = Pack::Indexer::DEFAULT_MAX_OBJECT_BYTES,
                   max_objects : Int64 = 40_000_000,
                   check : Proc(Nil)? = nil) : Pack::Published
      check!
      directory = File.join(@common, "objects", "pack")
      Dir.mkdir(directory, 0o755) unless File.info?(directory, follow_symlinks: false)
      raise Error.new("Git pack directory missing or redirected") unless Dir.exists?(directory) &&
                                                                         !File.symlink?(directory) && File.realpath(directory) == directory
      temp = File.join(directory, "tmp_pack_#{Random::Secure.hex(12)}")
      temporaries = [temp]
      begin
        local = ->(oid : String) : RawObject? do
          if @object_database.has_object?(oid)
            type, data = @object_database.object(oid, max_object_bytes.clamp(1_i64, Int32::MAX.to_i64 - 129).to_i32) { check.try &.call }
            RawObject.new(ObjectType.parse(type), data)
          end
        end
        indexer = Pack::Indexer.new(@object_format, max_object_bytes: max_object_bytes,
          max_objects: max_objects, local_object: local, fix_thin: fix_thin,
          check_collisions: check_collisions, check: check)
        result = indexer.index_stream(input, temp)
        if result.entries.empty?
          return Pack::Published.new(nil, nil, nil, result.entries, 0, nil)
        end
        checksum = result.checksum.hexbytes
        stem = File.join(directory, "pack-#{result.checksum}")
        final_pack = stem + ".pack"
        final_idx = stem + ".idx"
        if File.exists?(final_idx) && File.exists?(final_pack)
          # The same pack (named by its checksum) is already present.
          return Pack::Published.new(result.checksum, final_pack, final_idx, result.entries,
            result.appended, nil)
        end
        idx_temp = temp + ".idx"
        temporaries << idx_temp
        write_synced(idx_temp, Pack::IndexFile.encode(result.entries, checksum, @object_format))
        rev_temp = nil.as(String?)
        if write_rev
          rev_temp = temp + ".rev"
          temporaries << rev_temp
          write_synced(rev_temp, Pack::ReverseIndexFile.encode(result.entries, checksum, @object_format))
        end
        File.open(temp, "rb") { |io| io.fsync }
        check.try &.call
        publish_pack_file(temp, final_pack)
        rev_temp.try { |path| publish_pack_file(path, stem + ".rev") }
        keep_path = nil.as(String?)
        if message = keep
          keep_path = stem + ".keep"
          File.write(keep_path, message.ends_with?('\n') ? message : message + "\n") unless File.exists?(keep_path)
        end
        publish_pack_file(idx_temp, final_idx)
        File.open(directory) { |dir| dir.fsync }
        @object_database.refresh_packs
        Pack::Published.new(result.checksum, final_pack, final_idx, result.entries,
          result.appended, keep_path)
      ensure
        temporaries.each { |path| File.delete?(path) }
      end
    rescue ex : File::Error | IO::Error
      raise Error.new("Git pack indexing failed: #{ex.class}: #{ex.message}")
    end

    # Remove a .keep written by index_pack once refs point at its objects.
    def release_pack_keep(published : Pack::Published) : Nil
      published.keep_path.try { |path| File.delete?(path) }
    end

    private def write_synced(path : String, bytes : Bytes) : Nil
      File.open(path, "wb", perm: 0o444) do |io|
        io.write(bytes)
        io.flush
        io.fsync
      end
    end

    private def publish_pack_file(temp : String, final : String) : Nil
      File.chmod(temp, 0o444)
      begin
        File.link(temp, final)
      rescue File::AlreadyExistsError
        # A pack is named by its checksum; an existing file is the same pack.
      end
    end
  end
end
