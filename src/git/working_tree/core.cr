require "set"

module Git
  # Bounded observations of the on-disk working tree relative to the Git index.
  class WorkingTree
    record Change, path : String, status : String, index_oid : String?, worktree_oid : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field("path", PathBytes.json_display(path))
          json.field("path_raw_hex", path.to_slice.hexstring) unless path.valid_encoding?
          json.field("status", status)
          json.field("index_oid", index_oid)
          json.field("worktree_oid", worktree_oid)
        end
      end
    end

    def initialize(@root : String, @common : String, @index : Index,
                   @object_format : ObjectId::Format, @max_scan_bytes : Int32,
                   @max_search_entries : Int32)
    end

    private def validate_index_path!(path : String) : Nil
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
    end

    # Compare stage-zero index entries with on-disk tracked files, and walk
    # untracked paths without following symlinked directories. Note that this
    # is a bounded snapshot-like observation, not an atomic filesystem view.
    def changes(max_bytes : Int32, limit : Int32, *, include_untracked : Bool = true,
                allowed_path : Proc(String, Bool)? = nil, config : Config? = nil,
                &check : -> Nil) : {Array(Change), Bool, Int32}
      # The caller supplies an explicitly resolved Git config. Do not load
      # ambient/home configuration or follow arbitrary external paths here.
      mode_sensitive = config.try(&.boolean?("core.filemode")) != false
      index = @index.entries(max_bytes) { check.call }
      tracked = Set(String).new
      changes = [] of Change
      bytes_scanned = 0_i64
      index.each do |entry|
        check.call
        next if allowed_path && !allowed_path.call(entry.path)
        tracked.add(entry.path)
        if entry.stage != 0
          changes << Change.new(entry.path, "unmerged", entry.oid, nil)
          next
        end
        next if entry.skip_worktree
        verify_working_parents!(entry.path) { check.call }
        absolute = File.join(@root, entry.path)
        if File.symlink?(absolute)
          # The object may be a symlink, but the caller must decide whether
          # to authorize it. Never follow a link into another filesystem tree.
          if entry.mode == "120000"
            before = File.info(absolute, follow_symlinks: false)
            target = File.readlink(absolute)
            after = File.info(absolute, follow_symlinks: false)
            raise Error.new("Git working symlink changed during read") unless after.same_file?(before) &&
                                                                              after.modification_time == before.modification_time && File.symlink?(absolute)
            bytes_scanned += target.bytesize
            raise Error.new("Git working tree scan budget exceeded") if bytes_scanned > @max_scan_bytes
            oid = ObjectId.digest("blob", target, @object_format)
            changes << Change.new(entry.path, "modified", entry.oid, oid) if oid != entry.oid
          else
            changes << Change.new(entry.path, "typechanged", entry.oid, nil)
          end
          next
        end
        unless File.exists?(absolute)
          changes << Change.new(entry.path, "deleted", entry.oid, nil)
          next
        end
        if entry.mode == "160000"
          changes << Change.new(entry.path, "submodule_unsupported", entry.oid, nil)
          next
        end
        unless File.file?(absolute) && !File.symlink?(absolute)
          changes << Change.new(entry.path, "typechanged", entry.oid, nil)
          next
        end
        remaining = @max_scan_bytes.to_i64 - bytes_scanned
        raise Error.new("Git working tree scan budget exceeded") if remaining < 0
        oid, mode, data = read_working_regular(entry.path, {max_bytes.to_i64, remaining}.min.to_i) { check.call }
        bytes_scanned += data.bytesize
        if oid != entry.oid || (mode_sensitive && (entry.mode == "100755") != (mode == "100755")) || entry.mode == "120000"
          changes << Change.new(entry.path, "modified", entry.oid, oid)
        end
      end
      ignored_count = 0
      if include_untracked
        ignore = Ignore.new(@root, @common, {max_bytes, @max_scan_bytes}.min, allowed_path)
        queue = [{"", 0}]
        visited = 0
        until queue.empty?
          prefix, depth = queue.pop
          check.call
          raise Error.new("Git working tree depth exceeded") if depth > Metadata::MAX_DEPTH
          location = prefix.empty? ? @root : File.join(@root, prefix)
          raise Error.new("Git working directory redirected") if File.symlink?(location) || !Dir.exists?(location) || File.realpath(location) != location
          Dir.each_child(location) do |name|
            visited += 1
            raise Error.new("Git working tree entry budget exceeded") if visited > @max_search_entries
            next if name == ".git"
            relative = prefix.empty? ? name : "#{prefix}/#{name}"
            validate_index_path!(relative)
            next if allowed_path && !allowed_path.call(relative)
            full = File.join(@root, relative)
            is_dir = !File.symlink?(full) && Dir.exists?(full)
            if ignore.ignored?(relative, is_dir)
              ignored_count += 1
              next
            end
            if is_dir
              queue << {relative, depth + 1}
            elsif !tracked.includes?(relative)
              changes << Change.new(relative, "untracked", nil, nil)
            end
          end
        end
      end
      changes.sort_by!(&.path)
      {changes.first(limit), changes.size > limit, ignored_count}
    end

    # Worktree changes, at most a caller-chosen number of them.
    struct ChangeList
      include Indexable(Change)

      # Whether more changes exist than were listed.
      getter? truncated : Bool
      # How many ignored paths were skipped.
      getter ignored : Int32

      def initialize(@changes : Array(Change), @truncated : Bool, @ignored : Int32)
      end

      def size : Int32
        @changes.size
      end

      def unsafe_fetch(index : Int) : Change
        @changes.unsafe_fetch(index)
      end
    end

    record FileComparison, path : String, old_oid : String, new_oid : String?, old_mode : String,
      new_mode : String?, old_text : String, new_text : String

    # Compare one indexed regular file with its raw working-tree bytes. No
    # Git filters or executables are consulted. Host authorization is separate.
    def file_comparison(path : String, max_bytes : Int32, *, config : Config? = nil,
                        &check : -> Nil) : FileComparison?
      mode_sensitive = config.try(&.boolean?("core.filemode")) != false
      validate_index_path!(path)
      check.call
      entries = @index.entries(max_bytes) { check.call }.select { |entry| entry.path == path }
      return nil if entries.empty?
      raise Error.new("unmerged or intent-to-add Git paths cannot be diffed") unless entries.size == 1 && entries[0].stage == 0 && !entries[0].intent && !entries[0].skip_worktree
      entry = entries[0]
      raise Error.new("only regular indexed Git files can be diffed") unless entry.mode == "100644" || entry.mode == "100755"
      old_text = @index.blob_text(entry.oid, max_bytes) { check.call }
      absolute = File.join(@root, path)
      verify_working_parents!(path) { check.call }
      new_text = ""
      new_mode = nil.as(String?)
      new_oid = nil.as(String?)
      if File.symlink?(absolute)
        raise Error.new("Git working file is a symlink")
      elsif File.exists?(absolute)
        new_oid, new_mode, new_text = read_working_regular(path, max_bytes) { check.call }
        raise Error.new("Git binary working content cannot be diffed") unless new_text.valid_encoding? && !new_text.includes?('\0')
      end
      check.call
      return nil if new_oid == entry.oid && (new_mode == entry.mode || !mode_sensitive)
      FileComparison.new(path, entry.oid, new_oid, entry.mode, new_mode, old_text, new_text)
    rescue ex : IO::Error
      raise Error.new("Git working diff I/O invalid: #{ex.class}")
    end
  end

  class Repository
    # Paths whose worktree state differs from the index, and untracked
    # files unless include_untracked is false, at most limit of them.
    # allowed_path filters what is reported; config supplies core.filemode
    # and the excludes file.
    def working_changes(*, max_bytes : Int32 = 8_388_608, limit : Int32 = 1_000,
                        include_untracked : Bool = true,
                        allowed_path : Proc(String, Bool)? = nil, config : Config? = nil,
                        check : Proc(Nil)? = nil) : WorkingTree::ChangeList
      require_worktree!
      changes, truncated, ignored = @worktree.changes(max_bytes, limit,
        include_untracked: include_untracked, allowed_path: allowed_path,
        config: config) { check.try &.call }
      WorkingTree::ChangeList.new(changes, truncated, ignored)
    end

    # The index's and the worktree's version of one path, or nil when they
    # agree.
    def working_file(path : String, *, max_bytes : Int32 = 8_388_608, config : Config? = nil,
                     check : Proc(Nil)? = nil) : WorkingTree::FileComparison?
      require_worktree!
      @worktree.file_comparison(path, max_bytes, config: config) { check.try &.call }
    end
  end
end
