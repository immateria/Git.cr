module Git
  class WorkingTree
    # Raw identity-checked read unless a caller supplies native conversion.
    # Publication receipts continue to observe the actual worktree bytes.
    protected def stage_content(path : String, max_bytes : Int32, *, conversion : Conversion? = nil,
                                index_oid : String? = nil, safe : Bool = false,
                                &check : -> Nil) : {String, String}
      oid, mode, bytes = read_working_regular(path, max_bytes) { check.call }
      bytes = conversion.clean(path, bytes, index_oid: index_oid, safe: safe) if conversion
      {mode, bytes}
    end
  end

  # Values and errors of Repository#stage.
  module Staging
    # Explicitly named paths that are untracked and ignored (git add refuses
    # these unless forced).
    class IgnoredPaths < Error
      getter paths : Array(String)

      def initialize(@paths : Array(String))
        super("The following paths are ignored by one of your .gitignore files: #{@paths.join(", ")}")
      end
    end

    # A named path that is neither tracked nor present in the working tree.
    class PathspecMismatch < Error
      getter pathspec : String

      def initialize(@pathspec : String, tracked_only : Bool)
        super(tracked_only ? "pathspec '#{@pathspec}' did not match any file(s) known to git" : "pathspec '#{@pathspec}' did not match any files")
      end
    end

    # A literal path or directory ("" is the whole tree) as a pathspec.
    protected def self.pathspec(raw : String) : String
      path = raw == "." ? "" : raw.rchop('/')
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH) unless path.empty?
      path
    end

    protected def self.covers?(spec : String, path : String) : Bool
      spec.empty? || path == spec || path.starts_with?(spec + "/")
    end
  end

  class Repository
    # Native subset of git add -- <path>: explicit, existing regular files
    # and symlinks. A symlink's target bytes are staged without following it.
    # Native text/EOL attributes apply to regular files. External filters and
    # pathspec expansion remain separate work.
    # The optional warning callback receives safecrlf=warn diagnostics before
    # index publication; callback exceptions propagate without staging.
    def stage_file(path : String, *, max_bytes : Int32 = 8_388_608,
                   max_index_bytes : Int32 = 8_388_608,
                   config : Config? = nil,
                   warning : Proc(String, Nil)? = nil,
                   check : Proc(Nil)? = nil) : String
      require_worktree!
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      conversion = Conversion.new(self, config: config, max_bytes: max_bytes,
        max_index_bytes: max_index_bytes, warning: warning, check: check)
      existing = @index.entries(max_index_bytes) { check.try &.call }.find { |entry| entry.path == path && entry.stage == 0 && {"100644", "100755"}.includes?(entry.mode) }
      full = File.join(@root, path)
      mode, bytes = if File.symlink?(full)
                      {"120000", Checkout.symlink_target(@root, path, max_bytes)}
                    else
                      @worktree.stage_content(path, max_bytes, conversion: conversion,
                        index_oid: existing.try(&.oid), safe: true) { check.try &.call }
                    end
      oid = write_blob(bytes, max_bytes: max_bytes.to_i64, check: check)
      # A warning callback may replace the working bytes after the read.
      # Never pair its new stat with the content read before the callback.
      stat = warning && !conversion.warnings.empty? ? nil : Index.stat_for(full, mode)
      @index.stage_entry(path, mode, oid, stat: stat, max_bytes: max_index_bytes, check: check)
      oid
    end

    # Stages worktree changes in one index write, like git add -A (or -u
    # with tracked_only), optionally limited to paths that are files or
    # directories. Deletions are staged as removals, new files are added
    # unless tracked_only, and conflicted paths resolve to stage 0. Ignored
    # paths are skipped, but an explicitly named untracked ignored file
    # raises Staging::IgnoredPaths and a path matching nothing raises
    # Staging::PathspecMismatch, both before anything is written. Submodules
    # are left alone. core.filemode comes from config. Returns the sorted
    # paths whose index entries changed.
    # With warning:, distinct safecrlf=warn diagnostics are reported once
    # per operation before index publication. Callback exceptions propagate.
    def stage(paths : Array(String)? = nil, *, tracked_only : Bool = false,
              max_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_paths : Int32 = 10_000, config : Config? = nil,
              warning : Proc(String, Nil)? = nil,
              check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      raise ArgumentError.new("invalid Git stage budgets") if max_bytes < 1 || max_index_bytes < 128 || max_paths < 1
      specs = [""]
      if given = paths
        raise Error.new("empty Git stage paths") if given.empty?
        specs = given.map { |raw| Staging.pathspec(raw) }.uniq
      end
      whole = specs.includes?("")
      selected_path = ->(path : String) { specs.any? { |spec| Staging.covers?(spec, path) } }
      allowed = nil.as(Proc(String, Bool)?)
      unless whole
        allowed = ->(path : String) do
          File.basename(path) == ".gitignore" || selected_path.call(path) || specs.any? { |spec| spec.starts_with?(path + "/") }
        end
      end
      mode_sensitive = config.try(&.boolean?("core.filemode")) != false
      conversion = Conversion.new(self, config: config, max_bytes: max_bytes,
        max_index_bytes: max_index_bytes, warning: warning, check: check)
      budget = {max_bytes, max_index_bytes}.max
      index = @index.entries(budget) { check.try &.call }
      by_path = {} of String => Array(Index::Entry)
      index.each { |entry| (by_path[entry.path] ||= [] of Index::Entry) << entry }
      gitlinks = index.select { |entry| entry.mode == "160000" }.map(&.path)
      unless whole
        ignore = Ignore.new(@root, @common, {max_bytes, @max_scan_bytes}.min, config: config)
        ignored = [] of String
        specs.each do |spec|
          check.try &.call
          tracked = by_path.keys.any? { |path| Staging.covers?(spec, path) }
          full = File.join(@root, spec)
          present = File.symlink?(full) || File.exists?(full)
          raise Staging::PathspecMismatch.new(spec, tracked_only) unless tracked || (present && !tracked_only)
          next if tracked_only || tracked || (Dir.exists?(full) && !File.symlink?(full))
          ignored << spec if ignore.ignored?(spec, false)
        end
        raise Staging::IgnoredPaths.new(ignored.sort!) unless ignored.empty?
      end
      found, truncated, _ = @worktree.changes(budget, max_paths,
        include_untracked: !tracked_only, allowed_path: allowed, selected_path: selected_path, config: config,
        conversion: conversion, safe_conversion: true, include_stat_dirty: true) { check.try &.call }
      raise Error.new("Git stage path budget exceeded") if truncated
      embedded = {} of String => Bool
      edits = {} of String => Index::Edit
      found.each do |change|
        check.try &.call
        path = change.path
        next if edits.has_key?(path) || !selected_path.call(path)
        next if gitlinks.any? { |link| Staging.covers?(link, path) }
        existing = by_path[path]?
        indexed = existing.try { |entries| entries.find { |entry| entry.stage == 0 && {"100644", "100755"}.includes?(entry.mode) } }
        status = change.status
        if status == "stat_dirty"
          edits[path] = Index::InvalidateStat.new(path)
          next
        end
        next if status == "untracked" && embedded_repository?(path, embedded)
        full = File.join(@root, path)
        symlink = File.symlink?(full)
        if status == "deleted" || (!symlink && !File.exists?(full))
          edits[path] = Index::Remove.new(path) if existing
        elsif !symlink && Dir.exists?(full)
          edits[path] = Index::Remove.new(path) if existing
        else
          mode, bytes = if symlink
                          {"120000", Checkout.symlink_target(@root, path, max_bytes)}
                        else
                          worktree_mode, content = @worktree.stage_content(path, max_bytes,
                            conversion: conversion, index_oid: indexed.try(&.oid), safe: true) { check.try &.call }
                          unless mode_sensitive
                            kept = existing.try(&.first?)
                            worktree_mode = kept && {"100644", "100755"}.includes?(kept.mode) ? kept.mode : "100644"
                          end
                          {worktree_mode, content}
                        end
          oid = write_blob(bytes, max_bytes: max_bytes.to_i64, check: check)
          unchanged = existing && existing.size == 1 && existing[0].stage == 0 &&
                      existing[0].mode == mode && existing[0].oid == oid
          if unchanged
            edits[path] = Index::InvalidateStat.new(path) if existing.try(&.first?).try(&.stat)
          else
            edits[path] = Index::Put.new(path, mode, oid, Index.stat_for(full, mode))
          end
        end
      end
      return [] of String if edits.empty?
      changes = edits.values
      if warning && !conversion.warnings.empty?
        # A later warning can edit any earlier staged file as well. Discard
        # every new cache record from this operation, not only the last one.
        changes.map! do |edit|
          edit.is_a?(Index::Put) ? Index::Put.new(edit.path, edit.mode, edit.oid).as(Index::Edit) : edit
        end
      end
      image = @index.prepare_changes(changes, max_bytes: max_index_bytes,
        max_entries: @max_search_entries, check: check)
      @index.publish_image(image, max_bytes: max_index_bytes, check: check)
      edits.values.reject { |edit| edit.is_a?(Index::InvalidateStat) }.map(&.path).sort!
    end

    # Whether a directory above path holds its own .git (an embedded
    # repository, which git add would record as a gitlink).
    private def embedded_repository?(path : String, cache : Hash(String, Bool)) : Bool
      prefix = ""
      path.split('/')[0...-1].any? do |part|
        prefix = prefix.empty? ? part : "#{prefix}/#{part}"
        cache[prefix] ||= File.exists?(File.join(@root, prefix, ".git"))
      end
    end
  end
end
