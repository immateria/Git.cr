module Git
  class Index
    record Put, path : String, mode : String, oid : String, stat : Stat? = nil
    record Remove, path : String
    # A complete set of unmerged index entries for one literal path. Git
    # represents a missing base/ours/theirs side by omitting that stage,
    # never by inventing a zero OID. This is index state, not a resolution.
    record PutStages, path : String, stages : Array(Entry)
    # Forget a worktree cache record without changing indexed content,
    # stages or flags. A later status must verify the file's actual bytes.
    record InvalidateStat, path : String
    alias Edit = Put | Remove | PutStages | InvalidateStat

    # :nodoc:
    # Complete, checksummed image, bound to the SHA-256 digest of the exact
    # predecessor (nil means the index was absent). This is a redo intent,
    # not permission to write or a guarantee of an atomic multi-file commit.
    record Image, before_sha256 : String?, data : String
    # :nodoc:
    record Plan, image : Image, entries : Array(Entry)

    # Fingerprint the complete index for best-effort staged snapshot guards.
    # This is not a descriptor-held atomic snapshot against hostile writers.
    protected def snapshot_checksum(max_bytes : Int32 = 8_388_608) : String?
      raise ArgumentError.new("invalid Git index byte budget") if max_bytes < 128
      @metadata.check!
      raw = read_index_bounded(File.join(@metadata.git_dir, "index"), max_bytes)
      raw ? ObjectId.checksum(raw, @object_format) : nil
    end

    # P18: one cooperative index transaction. The index is read only after
    # acquiring Git's exclusive .lock, then rebuilt in its existing DIRC
    # version (2, 3 or 4) and atomically published. Unsupported extensions
    # are refused; supported flags including CE_VALID and stat data are preserved.
    protected def stage_entry(path : String, mode : String, oid : String, *,
                              stat : Stat? = nil,
                              max_bytes : Int32 = 8_388_608, max_entries : Int32 = 100_000,
                              check : Proc(Nil)? = nil) : Nil
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      raise Error.new("unsupported Git staging mode") unless {"100644", "100755", "120000", "160000"}.includes?(mode)
      ObjectId.valid!(oid, @object_format)
      mutate_entry(path, Entry.new(path, mode, oid, 0, false, false, false, stat),
        max_bytes: max_bytes, max_entries: max_entries, check: check)
    end

    # Remove all stages for a tracked path from the index without touching
    # its worktree file. This deliberately differs from git rm's filesystem
    # side effects and performs no pathspec expansion or ignore filtering.
    protected def remove_entry(path : String, *, max_bytes : Int32 = 8_388_608,
                               max_entries : Int32 = 100_000, check : Proc(Nil)? = nil) : Nil
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      mutate_entry(path, nil, max_bytes: max_bytes, max_entries: max_entries, check: check)
    end

    # :nodoc:
    # Build a complete index image without publishing it. The result can be
    # journaled before any index or reference changes are made. Existing
    # stages/flags/stat data and v2/v3/v4 representation are retained, or refused.
    def prepare_changes(changes : Array(Edit), *, max_bytes : Int32 = 8_388_608,
                        max_entries : Int32 = 100_000,
                        check : Proc(Nil)? = nil) : Image
      prepare_changes_plan(changes, max_bytes: max_bytes, max_entries: max_entries, check: check).image
    end

    # :nodoc:
    def prepare_changes_plan(changes : Array(Edit), *, max_bytes : Int32 = 8_388_608,
                             max_entries : Int32 = 100_000,
                             check : Proc(Nil)? = nil) : Plan
      raise ArgumentError.new("invalid Git index write budgets") if max_bytes < 128 || max_entries < 1
      raise Error.new("empty Git index change set") if changes.empty?
      raise Error.new("Git index change budget exceeded") if changes.size > max_entries
      @metadata.check!
      path_index = File.join(@metadata.git_dir, "index")
      old_index_time = modified_at
      initial_raw = read_index_bounded(path_index, max_bytes)
      current = entries(max_bytes) { check.try &.call }
      observed_raw = read_index_bounded(path_index, max_bytes)
      raise Error.new("Git index changed while preparing") unless observed_raw == initial_raw
      version = observed_raw ? writable_index_version?(observed_raw) : 2_u32
      raise Error.new("unsupported Git index flags or extension for mutation") unless version
      by_path = {} of String => Array(Entry)
      current.each do |entry|
        # Do not carry forward a racily-clean stat record into a newer index
        # timestamp without re-hashing its file.
        kept = if (recorded = entry.stat) && (old_index_time.nil? || recorded.mtime.to_i64 >= old_index_time.to_unix)
                 Entry.new(entry.path, entry.mode, entry.oid, entry.stage, entry.intent, entry.skip_worktree, entry.assume_unchanged, nil)
               else
                 entry
               end
        (by_path[entry.path] ||= [] of Entry) << kept
      end
      seen = Set(String).new
      changes.each do |change|
        check.try &.call
        path = change.path
        PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
        raise Error.new("duplicate Git index change") unless seen.add?(path)
        existed = by_path.delete(path)
        case change
        when Put
          raise Error.new("unsupported Git staging mode") unless {"100644", "100755", "120000", "160000"}.includes?(change.mode)
          ObjectId.valid!(change.oid, @object_format)
          by_path[path] = [Entry.new(path, change.mode, change.oid, 0, false, false, false, change.stat)]
        when PutStages
          raise Error.new("empty Git conflict stages") if change.stages.empty? || change.stages.size > 3
          last_stage = 0
          staged = [] of Entry
          change.stages.each do |entry|
            raise Error.new("invalid Git conflict stage") unless entry.path == path && entry.stage > last_stage &&
                                                                 entry.stage <= 3 && !entry.intent && !entry.skip_worktree &&
                                                                 !entry.assume_unchanged &&
                                                                 {"100644", "100755", "120000", "160000"}.includes?(entry.mode)
            ObjectId.valid!(entry.oid, @object_format)
            staged << entry
            last_stage = entry.stage
          end
          by_path[path] = staged
        when Remove
          raise Error.new("Git index path not staged") unless existed
        when InvalidateStat
          raise Error.new("Git index path not staged") unless existed
          by_path[path] = existed.map do |entry|
            Entry.new(entry.path, entry.mode, entry.oid, entry.stage, entry.intent,
              entry.skip_worktree, entry.assume_unchanged, nil)
          end
        end
      end
      output = by_path.values.flatten
      raise Error.new("Git index entry budget exceeded") if output.size > max_entries || output.size > @max_search_entries
      output.sort_by! { |entry| {entry.path, entry.stage} }
      previous = ""
      previous_stage = -1
      output.each do |entry|
        check.try &.call
        PathBytes.validate_relative!(entry.path, max_depth: Metadata::MAX_DEPTH)
        raise Error.new("Git index v2 cannot encode extended flags") if version == 2 && (entry.intent || entry.skip_worktree)
        ObjectId.valid!(entry.oid, @object_format)
        raise Error.new("invalid Git index conflict stage") unless (0..3).includes?(entry.stage)
        if entry.path == previous && (entry.stage <= previous_stage || entry.stage == 0 || previous_stage == 0)
          raise Error.new("Git index contains duplicate or mixed conflict stages")
        end
        previous = entry.path
        previous_stage = entry.stage
      end
      paths = Set(String).new(output.map(&.path))
      paths.each do |path|
        components = path.split('/')
        (1...components.size).each do |n|
          raise Error.new("Git index file/directory collision") if paths.includes?(components.first(n).join('/'))
        end
      end
      image = Image.new(initial_raw.try { |raw| Digest::SHA256.hexdigest(raw) },
        encode_entries(output, version, max_bytes))
      validate_image!(image, max_bytes)
      @metadata.check!
      Plan.new(image, output)
    end

    # A verified image may be replayed safely: only the exact predecessor or
    # the exact desired state is admissible. A foreign index value is never
    # overwritten. The exclusive Git index.lock guards cooperative writers.
    protected def image_state(image : Image, *, max_bytes : Int32 = 8_388_608) : Symbol
      validate_image!(image, max_bytes)
      @metadata.check!
      raw = read_index_bounded(File.join(@metadata.git_dir, "index"), max_bytes)
      current = raw.try { |data| Digest::SHA256.hexdigest(data) }
      return :desired if current == Digest::SHA256.hexdigest(image.data)
      return :before if current == image.before_sha256
      raise Error.new("Git index recovery conflict: index differs from both recorded images")
    end

    protected def publish_image(image : Image, *, max_bytes : Int32 = 8_388_608,
                                check : Proc(Nil)? = nil) : Nil
      validate_image!(image, max_bytes)
      @metadata.check!
      dir = DescriptorPath::Directory.open(@metadata.git_dir)
      begin
        io = dir.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        owned = true
        begin
          check.try &.call
          state = image_state(image, max_bytes: max_bytes)
          return if state == :desired
          io.write(image.data.to_slice)
          io.flush
          io.fsync
          check.try &.call
          @metadata.check!
          raise Error.new("Git index changed during image publication") unless image_state(image, max_bytes: max_bytes) == :before
          # Rename relative to the pinned Git directory; ancestor swaps
          # cannot publish into a foreign Git index.
          raise Error.new("Git index directory replaced during publication") unless dir.attached_at?(@metadata.git_dir)
          dir.rename("index.lock", "index")
          owned = false
          dir.sync
        ensure
          if owned && dir.same_inode?("index.lock", io)
            dir.unlink("index.lock")
            dir.sync
          end
          io.close unless io.closed?
        end
      ensure
        dir.close
      end
    rescue ex : File::Error | IO::Error
      raise Error.new("Git index image write failed: #{ex.class}")
    end

    private def validate_image!(image : Image, max_bytes : Int32) : Nil
      raise ArgumentError.new("invalid Git index byte budget") if max_bytes < 128
      if before = image.before_sha256
        raise Error.new("invalid predecessor Git index checksum") unless /\A[0-9a-f]{64}\z/.matches?(before)
      end
      raw = image.data
      raise Error.new("Git index image budget exceeded") if raw.bytesize > max_bytes
      raise Error.new("unsupported Git index image") unless writable_index_version?(raw)
      digest_len = @object_format.bytesize
      body = raw.byte_slice(0, raw.bytesize - digest_len)
      raise Error.new("Git index image checksum mismatch") unless ObjectId.checksum(body, @object_format) == raw.byte_slice(raw.bytesize - digest_len, digest_len).to_slice.hexstring
    end

    private def mutate_entry(path : String, incoming : Entry?, *,
                             max_bytes : Int32, max_entries : Int32,
                             check : Proc(Nil)?) : Nil
      change = if entry = incoming
                 Put.new(path, entry.mode, entry.oid, entry.stat).as(Edit)
               else
                 Remove.new(path).as(Edit)
               end
      @metadata.check!
      dir = DescriptorPath::Directory.open(@metadata.git_dir)
      begin
        io = dir.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        owned = true
        begin
          image = prepare_changes([change], max_bytes: max_bytes, max_entries: max_entries, check: check)
          check.try &.call
          io.write(image.data.to_slice)
          io.flush
          io.fsync
          check.try &.call
          @metadata.check!
          raise Error.new("Git index directory replaced during publication") unless dir.attached_at?(@metadata.git_dir)
          dir.rename("index.lock", "index")
          owned = false
          dir.sync
        ensure
          if owned && dir.same_inode?("index.lock", io)
            dir.unlink("index.lock")
            dir.sync
          end
          io.close unless io.closed?
        end
      ensure
        dir.close
      end
    rescue ex : File::Error | IO::Error
      raise Error.new("Git index write failed: #{ex.class}")
    end

    private def read_index_bounded(path : String, max_bytes : Int32) : String?
      DescriptorPath::Directory.with_parent(path) do |dir, name|
        io = dir.open_file?(name)
        next nil unless io
        begin
          info = io.info
          raise Error.new("Git index redirected") unless info.type.file?
          raise Error.new("Git index byte budget exceeded") if info.size > max_bytes
          data = IO::Memory.new
          IO.copy(io, data, max_bytes.to_i64 + 1)
          raise Error.new("Git index byte budget exceeded") if data.size > max_bytes
          data.to_s
        ensure
          io.close unless io.closed?
        end
      end
    end

    # In addition to validating extension signatures, find the entry section
    # without relying on decoded names or assuming v2 padding. This inspection
    # validates the index boundaries; Entry preserves CE_VALID and the known
    # extended flags. TREE is rebuildable.
    private def writable_index_version?(data : String) : UInt32?
      hash_size = @object_format.bytesize
      return nil if data.bytesize < 12 + hash_size || data.byte_slice(0, 4) != "DIRC"
      version = read_u32(data, 4)
      return nil unless {2_u32, 3_u32, 4_u32}.includes?(version)
      count = read_u32(data, 8).to_i64
      body_end = data.bytesize - hash_size
      pos = 12
      count.times do
        return nil if pos + 42 + hash_size > body_end
        start = pos
        flags = read_u16(data, start + 40 + hash_size)
        pos += 42 + hash_size
        if (flags & 0x4000) != 0
          return nil if version == 2 || pos + 2 > body_end
          pos += 2
        end
        if version == 4
          # Git's v4 prefix count is a variable-length number.
          loop do
            return nil if pos >= body_end
            continued = (data.byte_at(pos) & 0x80) != 0
            pos += 1
            break unless continued
          end
        end
        while pos < body_end && data.byte_at(pos) != 0
          pos += 1
        end
        return nil if pos >= body_end
        pos += 1
        if version != 4
          pos = start + ((pos - start + 7) // 8) * 8
          return nil if pos > body_end
        end
      end
      while pos < body_end
        return nil if pos + 8 > body_end || data.byte_slice(pos, 4) != "TREE"
        length = read_u32(data, pos + 4).to_i64
        pos += 8
        return nil if length > body_end - pos
        pos += length.to_i
      end
      pos == body_end ? version : nil
    end

    private def encode_entries(items : Array(Entry), version : UInt32, max_bytes : Int32) : String
      data = IO::Memory.new
      data.write("DIRC".to_slice)
      write_u32(data, version)
      write_u32(data, items.size.to_u32)
      previous = ""
      items.each do |entry|
        start = data.size
        if recorded = entry.stat
          write_u32(data, recorded.ctime)
          write_u32(data, recorded.ctime_nsec)
          write_u32(data, recorded.mtime)
          write_u32(data, recorded.mtime_nsec)
          write_u32(data, recorded.dev)
          write_u32(data, recorded.ino)
          write_u32(data, entry.mode.to_u32(8))
          write_u32(data, recorded.uid)
          write_u32(data, recorded.gid)
          write_u32(data, recorded.size)
        else
          6.times { write_u32(data, 0_u32) } # ctime, mtime, device, inode
          write_u32(data, entry.mode.to_u32(8))
          2.times { write_u32(data, 0_u32) } # uid, gid
          write_u32(data, 0_u32)             # stat size (recheck on next use)
        end
        data.write(entry.oid.hexbytes)
        extended = entry.intent || entry.skip_worktree
        raise Error.new("Git index v2 cannot encode extended flags") if version == 2 && extended
        flags = {entry.path.bytesize, 0xfff}.min | (entry.stage << 12)
        flags |= 0x4000 if extended
        flags |= 0x8000 if entry.assume_unchanged
        write_u16(data, flags.to_u16)
        if extended
          bits = 0_u16
          bits |= 0x2000 if entry.intent
          bits |= 0x4000 if entry.skip_worktree
          write_u16(data, bits)
        end
        if version == 4
          common = 0
          longest = {previous.bytesize, entry.path.bytesize}.min
          while common < longest && previous.byte_at(common) == entry.path.byte_at(common)
            common += 1
          end
          write_v4_prefix_removal(data, previous.bytesize - common)
          data.write(entry.path.byte_slice(common, entry.path.bytesize - common).to_slice)
          data.write_byte(0_u8)
        else
          data.write(entry.path.to_slice)
          pad = 8 - ((data.size - start) % 8)
          pad.times { data.write_byte(0_u8) }
        end
        previous = entry.path
        raise Error.new("Git index byte budget exceeded") if data.size.to_i64 + @object_format.bytesize > max_bytes
      end
      body = data.to_s
      data.write(ObjectId.checksum(body, @object_format).hexbytes)
      data.to_s
    end

    # Inverse of the v4 decoder's (value + 1) * 128 + next-byte recurrence.
    private def write_v4_prefix_removal(io : IO, count : Int32) : Nil
      value = count
      bytes = [((value & 0x7f).to_u8)]
      while value > 0x7f
        value = (value >> 7) - 1
        bytes << (((value & 0x7f) | 0x80).to_u8)
      end
      bytes.reverse_each { |byte| io.write_byte(byte) }
    end

    private def read_u16(raw : String, offset : Int32) : UInt16
      (raw.byte_at(offset).to_u16 << 8) | raw.byte_at(offset + 1).to_u16
    end

    private def read_u32(raw : String, offset : Int32) : UInt32
      (raw.byte_at(offset).to_u32 << 24) | (raw.byte_at(offset + 1).to_u32 << 16) |
        (raw.byte_at(offset + 2).to_u32 << 8) | raw.byte_at(offset + 3).to_u32
    end

    private def write_u16(io : IO, number : UInt16) : Nil
      io.write_byte(((number >> 8) & 0xff).to_u8)
      io.write_byte((number & 0xff).to_u8)
    end

    private def write_u32(io : IO, number : UInt32) : Nil
      io.write_byte(((number >> 24) & 0xff).to_u8)
      io.write_byte(((number >> 16) & 0xff).to_u8)
      io.write_byte(((number >> 8) & 0xff).to_u8)
      io.write_byte((number & 0xff).to_u8)
    end
  end

  class Repository
    # Stage explicit content in the index. This is independent of filter and
    # attribute processing or host-level authorization. Failed staging may leave
    # the newly written immutable blob unreachable.
    def stage_blob(path : String, content : String | Bytes, *, mode : String = "100644",
                   max_blob_bytes : Int64 = Int64::MAX,
                   max_index_bytes : Int32 = 8_388_608,
                   check : Proc(Nil)? = nil) : String
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      raise Error.new("unsupported Git blob staging mode") unless {"100644", "100755", "120000"}.includes?(mode)
      oid = write_blob(content, max_bytes: max_blob_bytes, check: check)
      @index.stage_entry(path, mode, oid, max_bytes: max_index_bytes, check: check)
      oid
    end

    # Stage an explicit removal from the index only. The worktree is neither
    # read nor modified. The next write_index_tree excludes this path.
    def remove_from_index(path : String, *, max_index_bytes : Int32 = 8_388_608,
                          check : Proc(Nil)? = nil) : Nil
      @index.remove_entry(path, max_bytes: max_index_bytes, check: check)
    end
  end
end
