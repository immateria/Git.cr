require "set"

module Git
  # :nodoc:
  # Index-only tree restoration: no worktree I/O, ref movement or subprocess.
  # Explicit source commits and literal paths avoid expanding user pathspecs.
  module IndexRestore
    record State, mode : String, oid : String

    protected def self.source_entries(repository : Repository, tree_oid : String, *,
                                      max_object_bytes : Int32, max_entries : Int32,
                                      check : Proc(Nil)?) : Hash(String, State)
      found = {} of String => State
      stack = [{"", tree_oid, 0}]
      visited = 0
      until stack.empty?
        check.try &.call
        prefix, oid, depth = stack.pop
        raise Error.new("Git index restore tree depth exceeded") if depth > Metadata::MAX_DEPTH
        kind, bytes = repository.object(oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git index restore expected tree") unless kind == "tree"
        repository.checkout_tree_entries(bytes).each do |name, mode, entry_oid|
          visited += 1
          raise Error.new("Git index restore entry budget exceeded") if visited > max_entries
          path = prefix + name
          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
          if mode == "40000"
            stack << {"#{path}/", entry_oid, depth + 1}
          else
            raise Error.new("unsupported Git index restore entry mode") unless {"100644", "100755", "120000", "160000"}.includes?(mode)
            raise Error.new("duplicate Git index restore path") if found.has_key?(path)
            found[path] = State.new(mode, entry_oid)
          end
        end
      end
      found
    end

    # Build a batch of index edits. Source-only additions, staged deletions,
    # and unmerged paths are handled, but unselected index records are not.
    protected def self.edits(current : Array(Index::Entry), source : Hash(String, State),
                             selected : Set(String)?) : Array(Index::Edit)
      grouped = {} of String => Array(Index::Entry)
      current.each do |entry|
        next if selected && !selected.includes?(entry.path)
        (grouped[entry.path] ||= [] of Index::Entry) << entry
      end
      names = selected ? selected.to_a : (grouped.keys + source.keys).uniq
      changes = [] of Index::Edit
      names.sort.each do |path|
        if entries = grouped[path]?
          if state = source[path]?
            next if entries.size == 1 && entries[0].stage == 0 && !entries[0].intent &&
                    !entries[0].skip_worktree && !entries[0].assume_unchanged &&
                    entries[0].mode == state.mode && entries[0].oid == state.oid
          end
        elsif !source.has_key?(path)
          raise Error.new("Git index restore path is neither indexed nor in source") if selected
          next
        end
        if desired = source[path]?
          changes << Index::Put.new(path, desired.mode, desired.oid)
        else
          changes << Index::Remove.new(path)
        end
      end
      changes
    end
  end

  class Repository
    # Equivalent in effect to `git restore --staged --source=REV -- FILE...`
    # for exact literal paths. Includes index-only symlinks and gitlinks, but
    # never expands globs or modifies HEAD/worktree. Unselected index entries
    # and their flags/stages are preserved. The Git index lock is cooperative.
    def restore_staged(paths : Array(String), *, source : String = "HEAD",
                       max_object_bytes : Int32 = 8_388_608,
                       max_index_bytes : Int32 = 8_388_608,
                       max_entries : Int32 = 10_000,
                       check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      raise ArgumentError.new("invalid Git index restore budgets") if max_object_bytes < 128 ||
                                                                      max_index_bytes < 128 || max_entries < 1 || max_entries > @max_search_entries
      raise Error.new("empty Git index restore paths") if paths.empty? || paths.size > max_entries
      chosen = Set(String).new
      paths.each do |path|
        PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
        raise Error.new("duplicate Git index restore path") unless chosen.add?(path)
      end
      source_oid = History.resolve_commit(self, source, max_object_bytes, check)
      tree_oid = read_commit(source_oid, max_bytes: max_object_bytes, check: check).tree
      desired = IndexRestore.source_entries(self, tree_oid, max_object_bytes: max_object_bytes,
        max_entries: max_entries, check: check)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git index restore entry budget exceeded") if current.size > max_entries
      edits = IndexRestore.edits(current, desired, chosen)
      return [] of String if edits.empty?
      image = @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries, check: check)
      guard = -> do
        check.try &.call
        raise Error.new("Git index restore source changed") unless History.resolve_commit(self, source, max_object_bytes, check) == source_oid
      end
      @index.publish_image(image, max_bytes: max_index_bytes, check: guard)
      edits.map(&.path)
    end

    # Equivalent to replacing the entire index with the selected commit tree,
    # without moving HEAD or modifying the worktree (`git read-tree --reset`
    # behavior for simple single-tree resets). Keeps staged conflicts out of
    # the resulting index, including when the target tree is empty.
    def read_tree(source : String = "HEAD", *,
                  max_object_bytes : Int32 = 8_388_608,
                  max_index_bytes : Int32 = 8_388_608,
                  max_entries : Int32 = 10_000,
                  check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      raise ArgumentError.new("invalid Git index reset budgets") if max_object_bytes < 128 ||
                                                                    max_index_bytes < 128 || max_entries < 1 || max_entries > @max_search_entries
      source_oid = History.resolve_commit(self, source, max_object_bytes, check)
      tree_oid = read_commit(source_oid, max_bytes: max_object_bytes, check: check).tree
      desired = IndexRestore.source_entries(self, tree_oid, max_object_bytes: max_object_bytes,
        max_entries: max_entries, check: check)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git index reset entry budget exceeded") if current.size > max_entries
      edits = IndexRestore.edits(current, desired, nil)
      return [] of String if edits.empty?
      image = @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries, check: check)
      guard = -> do
        check.try &.call
        raise Error.new("Git index reset source changed") unless History.resolve_commit(self, source, max_object_bytes, check) == source_oid
      end
      @index.publish_image(image, max_bytes: max_index_bytes, check: guard)
      edits.map(&.path)
    end
  end
end
