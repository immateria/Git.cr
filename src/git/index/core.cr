module Git
  # The Git staging index owns its entries, decoding, and HEAD comparison.
  class Index
    # The Git index is a snapshot of the staging area, not of the working
    # tree. These values deliberately carry no filesystem write authority.
    record Entry, path : String, mode : String, oid : String, stage : Int32,
      intent : Bool, skip_worktree : Bool, assume_unchanged : Bool = false

    record Change, path : String, status : String, head_oid : String?,
      index_oid : String?, stage : Int32?, head_mode : String?, index_mode : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field("path", PathBytes.json_display(path))
          json.field("path_raw_hex", path.to_slice.hexstring) unless path.valid_encoding?
          json.field("status", status)
          json.field("head_oid", head_oid)
          json.field("index_oid", index_oid)
          json.field("stage", stage)
          json.field("head_mode", head_mode)
          json.field("index_mode", index_mode)
        end
      end
    end

    # Staged changes, at most a caller-chosen number of them.
    struct ChangeList
      include Indexable(Change)

      # Whether more changes exist than were listed.
      getter? truncated : Bool

      def initialize(@changes : Array(Change), @truncated : Bool)
      end

      def size : Int32
        @changes.size
      end

      def unsafe_fetch(index : Int) : Change
        @changes.unsafe_fetch(index)
      end
    end

    record FileComparison, path : String, old_oid : String?, new_oid : String?, old_mode : String?, new_mode : String?,
      old_text : String, new_text : String

    def initialize(@metadata : Metadata, @head_tree : HeadTree,
                   @object_database : ObjectDatabase, @object_format : ObjectId::Format,
                   @max_search_entries : Int32)
    end

    # Compare HEAD's full tracked tree with the staged index. No worktree
    # reads, ignores, filters, hooks, or executable invocation are needed.
    def changes(max_bytes : Int32, limit : Int32, &check : -> Nil) : {Array(Change), Bool}
      check.call
      staged = entries(max_bytes) { check.call }
      head_files = {} of String => {String, String}
      if head_oid = @metadata.head[1]
        tree_oid = Commit.read(@object_database, head_oid, @object_format, max_bytes) { check.call }.tree
        nodes = [{"", tree_oid, 0}]
        visited = 0
        until nodes.empty?
          prefix, oid, depth = nodes.pop
          check.call
          raise Git::Error.new("Git tree traversal too deep") if depth > Metadata::MAX_DEPTH
          kind, data = @object_database.object(oid, max_bytes) { check.call }
          raise Git::Error.new("Git HEAD tree object invalid") unless kind == "tree"
          @head_tree.parse_tree(data).each do |name, mode, entry_oid|
            visited += 1
            raise Git::Error.new("Git HEAD tree entry budget exceeded") if visited > @max_search_entries
            path = prefix + name
            validate_index_path!(path)
            if mode == "40000"
              nodes << {path + "/", entry_oid, depth + 1}
            else
              head_files[path] = {mode, entry_oid}
            end
          end
        end
      end
      present = Set(String).new
      changes = [] of Change
      staged.each do |entry|
        check.call
        # Git may track or stage workspace lease metadata and hidden
        # credentials. Do not reveal paths forbidden by the host policy.
        present.add(entry.path)
        head_mode, head_oid = if old = head_files[entry.path]?
                                old
                              else
                                {nil, nil}
                              end
        status = if entry.stage != 0
                   "unmerged"
                 elsif entry.intent
                   "intent_to_add"
                 elsif head_oid.nil?
                   "added"
                 elsif head_oid != entry.oid || head_mode != entry.mode
                   "modified"
                 else
                   nil
                 end
        if status
          changes << Change.new(entry.path, status, head_oid, entry.oid,
            entry.stage, head_mode, entry.mode)
        end
      end
      head_files.each do |path, old|
        check.call
        next if present.includes?(path)
        changes << Change.new(path, "deleted", old[1], nil, nil, old[0], nil)
      end
      changes.sort_by! { |entry| {entry.path, entry.stage || -1} }
      {changes.first(limit), changes.size > limit}
    end

    # Versions 2/3 use 8-byte padded entries. Version 4 shares the stat
    # header but prefix-compresses names and has no padding. Unsupported
    # required extensions (notably sparse/split index) must fail closed.
    def entries(max_bytes : Int32, &check : -> Nil) : Array(Entry)
      file = File.join(@metadata.git_dir, "index")
      raise Git::Error.new("Git index symlink refused") if File.symlink?(file)
      return [] of Entry unless File.exists?(file)
      raise Git::Error.new("Git index is not a regular file") unless File.file?(file) && File.realpath(file) == file
      raise Git::Error.new("Git index byte budget exceeded") if max_bytes < 12 + @object_format.bytesize
      buffer = IO::Memory.new
      File.open(file) { |io| IO.copy(io, buffer, max_bytes.to_i64 + 1) }
      raise Git::Error.new("Git index byte budget exceeded") if buffer.size > max_bytes
      raw = buffer.to_s
      hash_size = @object_format.bytesize
      raise Git::Error.new("Git index truncated") if raw.bytesize < 12 + hash_size
      body_len = raw.bytesize - hash_size
      actual = ObjectId.checksum(raw.byte_slice(0, body_len), @object_format)
      expected = raw.byte_slice(body_len, hash_size).to_slice.hexstring
      raise Git::Error.new("Git index checksum mismatch") unless actual == expected
      raise Git::Error.new("Git index signature invalid") unless raw.byte_slice(0, 4) == "DIRC"
      version = index_u32(raw, 4)
      raise Git::Error.new("unsupported Git index version") unless {2_u32, 3_u32, 4_u32}.includes?(version)
      count = index_u32(raw, 8).to_i64
      raise Git::Error.new("Git index entry budget exceeded") if count > @max_search_entries
      entries = [] of Entry
      pos = 12
      previous = ""
      previous_stage = -1
      count.times do
        check.call
        start = pos
        raise Git::Error.new("Git index entry truncated") if pos + 42 + hash_size > body_len
        raw_mode = index_u32(raw, pos + 24)
        mode = raw_mode.to_s(8)
        raise Git::Error.new("unsupported Git index entry mode") unless {"100644", "100755", "120000", "160000"}.includes?(mode)
        oid = raw.byte_slice(pos + 40, hash_size).to_slice.hexstring
        flags = index_u16(raw, pos + 40 + hash_size)
        stage = ((flags >> 12) & 3).to_i
        pos += 42 + hash_size
        if (flags & 0x4000) != 0
          raise Git::Error.new("Git index v2 extended flags") if version == 2
          raise Git::Error.new("Git index extended entry truncated") if pos + 2 > body_len
          extended = index_u16(raw, pos)
          raise Git::Error.new("unsupported Git index extended flags") if (extended & 0x9fff) != 0
          pos += 2
        else
          extended = 0_u16
        end
        if version == 4
          first = index_byte(raw, pos, body_len)
          pos += 1
          removed = (first & 0x7f).to_i64
          while (first & 0x80) != 0
            first = index_byte(raw, pos, body_len)
            pos += 1
            removed = (removed + 1) * 128 + (first & 0x7f)
            raise Git::Error.new("Git index prefix too long") if removed > previous.bytesize
          end
          raise Git::Error.new("Git index prefix invalid") if removed > previous.bytesize
          suffix, pos = index_path_suffix(raw, pos, body_len)
          path = previous.byte_slice(0, previous.bytesize - removed.to_i) + suffix
        else
          path, pos = index_path_suffix(raw, pos, body_len)
          aligned = start + ((pos - start + 7) // 8) * 8
          raise Git::Error.new("Git index entry padding truncated") if aligned > body_len
          while pos < aligned
            raise Git::Error.new("Git index nonzero padding") unless raw.byte_at(pos) == 0
            pos += 1
          end
        end
        raise Git::Error.new("Git index path length mismatch") if (flags & 0xfff) != 0xfff && (flags & 0xfff) != path.bytesize
        validate_index_path!(path)
        if previous > path || (previous == path && (stage <= previous_stage || stage == 0 || previous_stage == 0))
          raise Git::Error.new("Git index entries out of order or mixed conflict stages")
        end
        entries << Entry.new(path, mode, oid, stage,
          (extended & 0x2000) != 0, (extended & 0x4000) != 0,
          (flags & 0x8000) != 0)
        previous = path
        previous_stage = stage
      end
      while pos < body_len
        check.call
        raise Git::Error.new("Git index extension truncated") if pos + 8 > body_len
        signature = raw.byte_slice(pos, 4)
        size = index_u32(raw, pos + 4).to_i64
        pos += 8
        raise Git::Error.new("Git index extension exceeds bounds") if size > body_len - pos
        first = signature.byte_at(0)
        raise Git::Error.new("unsupported required Git index extension") unless first >= 65 && first <= 90
        pos += size.to_i
      end
      entries
    rescue ex : IO::Error
      raise Git::Error.new("Git index I/O invalid: #{ex.class}")
    end

    private def index_u16(raw : String, pos : Int32) : UInt16
      ((raw.byte_at(pos).to_u16 << 8) | raw.byte_at(pos + 1).to_u16)
    end

    private def index_u32(raw : String, pos : Int32) : UInt32
      (raw.byte_at(pos).to_u32 << 24) | (raw.byte_at(pos + 1).to_u32 << 16) |
        (raw.byte_at(pos + 2).to_u32 << 8) | raw.byte_at(pos + 3).to_u32
    end

    private def index_byte(raw : String, pos : Int32, end_pos : Int32) : UInt8
      raise Git::Error.new("Git index path truncated") if pos >= end_pos
      raw.byte_at(pos)
    end

    private def index_path_suffix(raw : String, pos : Int32, end_pos : Int32) : {String, Int32}
      start = pos
      while pos < end_pos && raw.byte_at(pos) != 0
        pos += 1
        raise Git::Error.new("Git index path too long") if pos - start > 4096
      end
      raise Git::Error.new("Git index path terminator missing") if pos == end_pos
      {raw.byte_slice(start, pos - start), pos + 1}
    end

    private def validate_index_path!(path : String) : Nil
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
    end

    def file_comparison(path : String, max_bytes : Int32, &check : -> Nil) : FileComparison?
      validate_index_path!(path)
      entry = entries(max_bytes) { check.call }.find { |e| e.path == path }
      raise Error.new("unmerged or intent-to-add paths cannot be diffed") if entry && (entry.stage != 0 || entry.intent)
      old = nil.as({String, String}?)
      if head_oid = @metadata.head[1]
        # A missing historical path is normal for staged additions.
        begin
          old = @head_tree.head_entry(path, max_bytes) { check.call }
        rescue ex : Error
          raise ex unless ex.message == "path not present in Git HEAD tree"
        end
      end
      return nil unless entry || old
      new_mode = entry.try(&.mode)
      new_oid = entry.try(&.oid)
      old_mode = old.try(&.[0])
      old_oid = old.try(&.[1])
      return nil if old_oid == new_oid && old_mode == new_mode
      raise Error.new("only regular Git files can be diffed") unless [old_mode, new_mode].compact.all? { |x| x == "100644" || x == "100755" }
      old_text = old_oid ? blob_text(old_oid, max_bytes) { check.call } : ""
      new_text = new_oid ? blob_text(new_oid, max_bytes) { check.call } : ""
      FileComparison.new(path, old_oid, new_oid, old_mode, new_mode, old_text, new_text)
    end

    def blob_text(oid : String, max_bytes : Int32, &check : -> Nil) : String
      kind, data = @object_database.object(oid, max_bytes) { check.call }
      raise Error.new("Git staged object is not a text blob") unless kind == "blob" && data.valid_encoding? && !data.includes?('\0')
      data
    end
  end

  class Repository
    # Paths whose staged state differs from HEAD (`git diff --cached
    # --name-status`), at most limit of them.
    def staged_changes(*, max_bytes : Int32 = 8_388_608, limit : Int32 = 1_000,
                       check : Proc(Nil)? = nil) : Index::ChangeList
      changes, truncated = @index.changes(max_bytes, limit) { check.try &.call }
      Index::ChangeList.new(changes, truncated)
    end

    # HEAD's and the index's version of one path, or nil when they agree.
    def staged_file(path : String, *, max_bytes : Int32 = 8_388_608,
                    check : Proc(Nil)? = nil) : Index::FileComparison?
      @index.file_comparison(path, max_bytes) { check.try &.call }
    end
  end
end
