module Git
  # Errors of Repository#remove.
  module Removal
    # git rm's safety checks failed: these tracked files hold work that
    # removal would lose. staged_only files differ from HEAD in the index,
    # modified files differ from the index in the worktree, and both
    # differ from each other and from HEAD.
    class Refused < Error
      getter staged_only : Array(String)
      getter modified : Array(String)
      getter both : Array(String)

      def initialize(@staged_only : Array(String), @modified : Array(String), @both : Array(String))
        parts = [] of String
        parts << "#{@both.join(", ")} has staged content different from both the file and the HEAD" unless @both.empty?
        parts << "#{@staged_only.join(", ")} has changes staged in the index" unless @staged_only.empty?
        parts << "#{@modified.join(", ")} has local modifications" unless @modified.empty?
        super("Git refuses to remove: #{parts.join("; ")}")
      end

      # Every offending path, sorted.
      def paths : Array(String)
        (@staged_only + @modified + @both).sort!
      end
    end

    # A directory was named without recursive.
    class NotRecursive < Error
      getter path : String

      def initialize(@path : String)
        super("not removing '#{@path.empty? ? "." : @path}' recursively without -r")
      end
    end

    # The index was published, but a working file could not be deleted.
    class PartialRemoval < Error
      getter original_error : Exception

      def initialize(@original_error : Exception)
        super("Git rm updated the index but failed to delete working files (#{@original_error.class}); inspect the working tree")
      end
    end
  end

  class WorkingTree
    # What lies at a tracked path, without following links: {"missing"},
    # {"directory"}, {"other"} or {"file", mode, blob oid}.
    protected def removal_state(path : String, max_bytes : Int32, &check : -> Nil) : {String, String?, String?}
      verify_working_parents!(path) { check.call }
      full = File.join(@root, path)
      if File.symlink?(full)
        {"file", "120000", ObjectId.digest("blob", File.readlink(full), @object_format)}
      elsif !File.exists?(full)
        {"missing", nil, nil}
      elsif Dir.exists?(full)
        {"directory", nil, nil}
      elsif File.file?(full)
        oid, mode, _ = read_working_regular(path, max_bytes) { check.call }
        {"file", mode, oid}
      else
        {"other", nil, nil}
      end
    end
  end

  class Repository
    # Removes tracked paths from the index and, unless cached, from the
    # working tree (with directories left empty), like git rm [--cached] [-f]
    # [-r] -- <paths>. Each path is a tracked file or, with recursive, a
    # directory. Without force it refuses, with Removal::Refused, files whose
    # removal would lose staged or local work; cached refuses only when the
    # index matches neither HEAD nor the file. A path that is already gone
    # from the worktree is just removed from the index. Submodules are
    # refused. One index write; returns the sorted removed paths.
    def remove(paths : Array(String), *, cached : Bool = false, force : Bool = false,
               recursive : Bool = false, max_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608, max_paths : Int32 = 10_000,
               config : Config? = nil, check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      raise ArgumentError.new("invalid Git rm budgets") if max_bytes < 1 || max_index_bytes < 128 || max_paths < 1
      raise Error.new("empty Git rm paths") if paths.empty?
      specs = paths.map { |raw| Staging.pathspec(raw) }.uniq
      index = @index.entries(max_index_bytes) { check.try &.call }
      selected = Set(String).new
      specs.each do |spec|
        check.try &.call
        covered = index.select { |entry| Staging.covers?(spec, entry.path) }
        raise Staging::PathspecMismatch.new(spec, false) if covered.empty?
        raise Removal::NotRecursive.new(spec) if !recursive && covered.any? { |entry| entry.path != spec }
        covered.each { |entry| selected.add(entry.path) }
        raise Error.new("Git rm path budget exceeded") if selected.size > max_paths
      end
      matched = index.select { |entry| selected.includes?(entry.path) }
      raise Error.new("Git rm does not remove submodules") if matched.any? { |entry| entry.mode == "160000" }
      refuse_unsafe_removal!(matched, cached: cached, max_bytes: max_bytes, config: config, check: check) unless force
      removed = selected.to_a.sort!
      edits = removed.map { |path| Index::Remove.new(path).as(Index::Edit) }
      image = @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: @max_search_entries, check: check)
      @index.publish_image(image, max_bytes: max_index_bytes, check: check)
      begin
        delete_working_files(removed, check) unless cached
      rescue ex : Error | IO::Error | File::Error
        raise Removal::PartialRemoval.new(ex)
      end
      removed
    end

    private def refuse_unsafe_removal!(entries : Array(Index::Entry), *, cached : Bool,
                                       max_bytes : Int32, config : Config?,
                                       check : Proc(Nil)?) : Nil
      mode_sensitive = config.try(&.boolean?("core.filemode")) != false
      head = {} of String => IndexRestore::State
      if head_oid = head_ref_and_oid[1]
        tree = read_commit(head_oid, max_bytes: max_bytes, check: check).tree
        head = IndexRestore.source_entries(self, tree, max_object_bytes: max_bytes,
          max_entries: @max_search_entries, check: check)
      end
      staged_only = Set(String).new
      modified = Set(String).new
      both = Set(String).new
      entries.each do |entry|
        check.try &.call
        kind, mode, oid = @worktree.removal_state(entry.path, max_bytes) { check.try &.call }
        next if kind == "missing" || kind == "directory"
        local = if kind == "file"
                  entry.oid != oid || (entry.mode == "120000") != (mode == "120000") ||
                    (mode_sensitive && (entry.mode == "100755") != (mode == "100755"))
                else
                  true
                end
        committed = head[entry.path]?
        staged = committed.nil? || committed.mode != entry.mode || committed.oid != entry.oid
        if local && staged
          both.add(entry.path)
        elsif !cached
          staged_only.add(entry.path) if staged
          modified.add(entry.path) if local
        end
      end
      return if staged_only.empty? && modified.empty? && both.empty?
      raise Removal::Refused.new(staged_only.to_a.sort!, modified.to_a.sort!, both.to_a.sort!)
    end

    # Unlink each file or symlink, then remove the directories that are now
    # empty, deepest first, stopping at the first one that is not.
    private def delete_working_files(paths : Array(String), check : Proc(Nil)?) : Nil
      paths.each do |path|
        check.try &.call
        dir, leaf, location = Checkout.parent(@root, path, create: false)
        begin
          raise Error.new("Git working directory replaced during removal") unless dir.attached_at?(location)
          if stat = dir.stat?(leaf)
            if (stat.st_mode & LibC::S_IFMT) != LibC::S_IFDIR
              dir.unlink(leaf)
              dir.sync
            end
          end
        ensure
          dir.close
        end
      end
      parents = Set(String).new
      paths.each do |path|
        parts = path.split('/')[0...-1]
        (1..parts.size).each { |n| parents.add(parts.first(n).join('/')) }
      end
      parents.to_a.sort_by { |dir| {-dir.count('/'), dir} }.each do |dir|
        check.try &.call
        begin
          Checkout.remove_empty_directory(@root, dir, check: nil)
        rescue Error
          # Not empty (or already gone): Git stops there as well.
        end
      end
    end
  end
end
