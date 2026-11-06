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

    # :nodoc:
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
    protected def changes(max_bytes : Int32, limit : Int32, *, include_untracked : Bool = true,
                          allowed_path : Proc(String, Bool)? = nil,
                          selected_path : Proc(String, Bool)? = nil, config : Config? = nil,
                          conversion : Conversion? = nil, safe_conversion : Bool = false,
                          include_stat_dirty : Bool = false,
                          &check : -> Nil) : {Array(Change), Bool, Int32}
      # The caller supplies an explicitly resolved Git config. Do not load
      # ambient/home configuration or follow arbitrary external paths here.
      mode_sensitive = config.try(&.boolean?("core.filemode")) != false
      index_time = @index.modified_at
      index = @index.entries(max_bytes) { check.call }
      verified = Set(String).new
      tracked = Set(String).new
      submodules = index.select { |entry| entry.mode == "160000" }.map(&.path).to_set
      changes = [] of Change
      bytes_scanned = 0_i64
      index.each do |entry|
        check.call
        next if allowed_path && !allowed_path.call(entry.path)
        tracked.add(entry.path)
        # Ignore files may be admitted for traversal without being selected
        # for staging. Do not read or convert their tracked content here.
        next if selected_path && !selected_path.call(entry.path)
        if entry.stage != 0
          changes << Change.new(entry.path, "unmerged", entry.oid, nil)
          next
        end
        next if entry.skip_worktree
        next if stat_unchanged?(entry, mode_sensitive, index_time, verified) { check.call }
        verify_working_parents!(entry.path, verified) { check.call }
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
          # Like Git: an uninitialized submodule (no repository inside) is
          # unchanged; a checked-out one is modified when its HEAD is not
          # the recorded commit. Its own worktree is not inspected.
          if (checked_out = submodule_head(entry.path)) && checked_out != entry.oid
            changes << Change.new(entry.path, "modified", entry.oid, checked_out)
          end
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
        if conversion
          indexed_oid = {"100644", "100755"}.includes?(entry.mode) ? entry.oid : nil
          canonical = conversion.clean(entry.path, data, index_oid: indexed_oid, safe: safe_conversion)
          oid = ObjectId.digest("blob", canonical, @object_format)
        end
        if oid != entry.oid || (mode_sensitive && (entry.mode == "100755") != (mode == "100755")) || entry.mode == "120000"
          changes << Change.new(entry.path, "modified", entry.oid, oid)
        elsif include_stat_dirty && (recorded = entry.stat) && recorded.size != 0 && recorded.size != data.bytesize
          # Staging can invalidate stale stat data even when conversion
          # leaves the indexed object unchanged. Only a stale nonzero size
          # needs this: Git rehashes other stat differences on its own.
          changes << Change.new(entry.path, "stat_dirty", entry.oid, oid)
        end
      end
      ignored_count = 0
      if include_untracked
        ignore = Ignore.new(@root, @common, {max_bytes, @max_scan_bytes}.min, allowed_path, config: config)
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
            if ignore.ignored?(relative, is_dir, parents_checked: true)
              ignored_count += 1
              next
            end
            if is_dir
              # A submodule is one tracked path; an untracked repository is
              # listed as itself ("nested/"), as Git lists both.
              next if submodules.includes?(relative)
              if File.exists?(File.join(full, ".git"))
                changes << Change.new(relative + "/", "untracked", nil, nil) unless selected_path && !selected_path.call(relative)
                next
              end
              queue << {relative, depth + 1}
            elsif !tracked.includes?(relative) && (!selected_path || selected_path.call(relative))
              changes << Change.new(relative, "untracked", nil, nil)
            end
          end
        end
      end
      changes.sort_by!(&.path)
      {changes.first(limit), changes.size > limit, ignored_count}
    end

    # The commit a checked-out submodule's HEAD names, or nil when the
    # submodule directory holds no repository.
    private def submodule_head(path : String) : String?
      directory = File.join(@root, path)
      return nil unless Dir.exists?(directory) && !File.symlink?(directory) && File.exists?(File.join(directory, ".git"))
      Repository.new(directory).head.oid
    rescue Error
      nil
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

    # Compare one indexed regular file with its canonical working-tree bytes.
    # Native text/EOL conversion is optional; external filters are not invoked.
    protected def file_comparison(path : String, max_bytes : Int32, *, config : Config? = nil,
                                  conversion : Conversion? = nil,
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
        if conversion
          new_text = conversion.clean(path, new_text, index_oid: entry.oid)
          new_oid = ObjectId.digest("blob", new_text, @object_format)
        end
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
      conversion = Conversion.new(self, config: config, max_bytes: max_bytes, check: check)
      changes, truncated, ignored = @worktree.changes(max_bytes, limit,
        include_untracked: include_untracked, allowed_path: allowed_path,
        config: config, conversion: conversion) { check.try &.call }
      WorkingTree::ChangeList.new(changes, truncated, ignored)
    end

    # The index's and the worktree's version of one path, or nil when they
    # agree.
    def working_file(path : String, *, max_bytes : Int32 = 8_388_608, config : Config? = nil,
                     check : Proc(Nil)? = nil) : WorkingTree::FileComparison?
      require_worktree!
      conversion = Conversion.new(self, config: config, max_bytes: max_bytes, check: check)
      @worktree.file_comparison(path, max_bytes, config: config, conversion: conversion) { check.try &.call }
    end
  end
end
