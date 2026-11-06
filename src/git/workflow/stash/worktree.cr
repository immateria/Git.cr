module Git
  class Repository
    private def stash_normalize_apply_index!(*, max_object_bytes : Int32,
                                             max_index_bytes : Int32,
                                             max_entries : Int32,
                                             check : Proc(Nil)?) : Nil
      branch, head_oid = head_ref_and_oid
      raise Error.new("Git stash apply requires an existing symbolic branch") unless branch && branch.starts_with?("refs/heads/") && head_oid
      tree = read_commit(head_oid, max_bytes: max_object_bytes, check: check).tree
      desired = IndexRestore.source_entries(self, tree, max_object_bytes: max_object_bytes,
        max_entries: max_entries, check: check)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git stash apply index entry budget exceeded") if current.size > max_entries
      current.each do |entry|
        raise Error.new("Git stash apply has unexpected unresolved index") unless entry.stage == 0 && !entry.intent &&
                                                                                  !entry.skip_worktree && !entry.assume_unchanged
        unless desired.has_key?(entry.path)
          desired[entry.path] = IndexRestore::State.new(entry.mode, entry.oid)
        end
      end
      edits = IndexRestore.edits(current, desired, nil)
      return if edits.empty?
      image = @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries, check: check)
      guard = -> do
        check.try &.call
        raise Error.new("Git stash apply HEAD changed during index normalization") unless head_ref_and_oid == {branch, head_oid}
        raise Error.new("Git stash apply sequencer metadata reappeared") if sequencer_state?
      end
      @index.publish_image(image, max_bytes: max_index_bytes, check: guard)
    end

    # Collect leaves that are untracked by the current index. By default the
    # native ignore rules exclude ignored leaves; include_ignored bypasses that
    # filter and descends ignored directories for stash -a parity. The traversal
    # never follows symlinked directories and every leaf
    # is re-read later before publication by stash_verify_worktree_snapshot!.
    # Blobs are written before the stash commit so its third-parent tree never
    # references an object that has not already been durably materialized.
    private def stash_untracked_files(index_paths : Set(String), *,
                                      selected_paths : Set(String)?,
                                      include_ignored : Bool,
                                      conversion : Conversion,
                                      observed : Hash(String, Checkout::FileState),
                                      max_object_bytes : Int32,
                                      max_total_bytes : Int64,
                                      max_entries : Int32,
                                      check : Proc(Nil)?) : {Hash(String, Checkout::FileState), Int64}
      raise Error.new("Git stash total byte budget exceeded") if max_total_bytes < 0
      ignore = include_ignored ? nil : Ignore.new(@root, @common, {max_object_bytes, @max_scan_bytes}.min)
      found = {} of String => Checkout::FileState
      transferred = 0_i64
      if selected_paths
        selected_paths.to_a.sort.each do |relative|
          check.try &.call
          next if index_paths.includes?(relative)
          full = File.join(@root, relative)
          is_directory = !File.symlink?(full) && Dir.exists?(full)
          next if is_directory
          next if ignore && ignore.ignored?(relative, false)
          leaf = stash_worktree_leaf?(relative, max_object_bytes,
            allow_directory_missing: true, check: check)
          next unless leaf
          raise Error.new("Git stash untracked capture entry budget exceeded") if found.size >= max_entries
          state, raw = leaf
          transferred += raw.bytesize
          raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
          canonical = state.mode == "120000" ? raw : conversion.clean(relative, raw, safe: true)
          oid = ObjectId.digest("blob", canonical, @object_format)
          written = write_blob(canonical, max_bytes: max_object_bytes.to_i64, check: check)
          raise Error.new("Git stash untracked blob identity changed") unless written == oid
          found[relative] = Checkout::FileState.new(state.mode, oid)
          observed[relative] = state
        end
        return {found, transferred}
      end
      queue = [{"", 0}]
      visited = 0
      until queue.empty?
        prefix, depth = queue.pop
        check.try &.call
        raise Error.new("Git stash untracked depth exceeded") if depth > Metadata::MAX_DEPTH
        location = prefix.empty? ? @root : File.join(@root, prefix)
        raise Error.new("Git stash untracked directory redirected") if File.symlink?(location) ||
                                                                       !Dir.exists?(location) ||
                                                                       File.realpath(location) != location
        Dir.each_child(location) do |name|
          check.try &.call
          visited += 1
          raise Error.new("Git stash untracked entry budget exceeded") if visited > @max_search_entries
          next if name == ".git"
          relative = prefix.empty? ? name : "#{prefix}/#{name}"
          PathBytes.validate_relative!(relative, max_depth: Metadata::MAX_DEPTH)
          full = File.join(@root, relative)
          is_directory = !File.symlink?(full) && Dir.exists?(full)
          next if ignore && ignore.ignored?(relative, is_directory)
          if is_directory
            queue << {relative, depth + 1}
            next
          end
          next if index_paths.includes?(relative)
          raise Error.new("Git stash untracked capture entry budget exceeded") if found.size >= max_entries
          leaf = stash_worktree_leaf?(relative, max_object_bytes,
            allow_directory_missing: false, check: check) ||
                 raise Error.new("Git stash untracked leaf disappeared")
          state, raw = leaf
          transferred += raw.bytesize
          raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
          canonical = state.mode == "120000" ? raw : conversion.clean(relative, raw, safe: true)
          oid = ObjectId.digest("blob", canonical, @object_format)
          written = write_blob(canonical, max_bytes: max_object_bytes.to_i64, check: check)
          raise Error.new("Git stash untracked blob identity changed") unless written == oid
          found[relative] = Checkout::FileState.new(state.mode, oid)
          observed[relative] = state
        end
      end
      {found, transferred}
    end

    # Materialize the third-parent tree into bounded checkout writes before any
    # worktree mutation. This validates the Git stash shape and object modes up
    # front; destination collision checks still occur after the tracked replay,
    # matching Git's ordering without ever overwriting an existing untracked
    # path.
    private def stash_untracked_writes(untracked_oid : String?, *,
                                       max_object_bytes : Int32,
                                       max_total_bytes : Int64,
                                       max_entries : Int32,
                                       check : Proc(Nil)?) : {Array(Checkout::Write), Int64}
      return {[] of Checkout::Write, 0_i64} unless oid = untracked_oid
      untracked = read_commit(oid, max_bytes: max_object_bytes, check: check)
      raise Error.new("Git stash untracked parent shape invalid") unless untracked.parents.empty?
      files = Checkout.tree_files(self, untracked.tree,
        max_object_bytes: max_object_bytes, max_files: max_entries,
        check: check, allow_symlinks: true)
      Checkout.require_tree_paths!(files.keys, "Git stash untracked tree")
      transferred = 0_i64
      writes = [] of Checkout::Write
      files.keys.sort.each do |path|
        check.try &.call
        state = files[path]
        kind, raw = object(state.oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git stash untracked target is not a blob") unless kind == "blob"
        transferred += raw.bytesize
        raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
        writes << Checkout::Write.new(path, state.mode, state.oid, raw)
      end
      {writes, transferred}
    end

    # Compute the post-save worktree for --staged by applying the inverse
    # staged delta. The index is the merge base, the current worktree is ours,
    # and HEAD is theirs. Ordinary exact add/delete/modify cases resolve by
    # identity; bounded non-overlapping regular-file edits reuse the native
    # three-way text merge. Unsupported overlap fails before refs/stash is
    # published rather than leaving a Git-compatible but partially cleaned
    # staged-only save.
    private def stash_staged_cleanup_files(head_files : Hash(String, Checkout::FileState),
                                           index_files : Hash(String, Checkout::FileState),
                                           worktree_files : Hash(String, Checkout::FileState), *,
                                           max_object_bytes : Int32,
                                           max_total_bytes : Int64,
                                           check : Proc(Nil)?) : {Hash(String, Checkout::FileState), Int64}
      cleanup = {} of String => Checkout::FileState
      transferred = 0_i64
      names = (head_files.keys + index_files.keys + worktree_files.keys).uniq.sort
      names.each do |path|
        check.try &.call
        base = index_files[path]?
        ours = worktree_files[path]?
        theirs = head_files[path]?
        desired = if ours == theirs || theirs == base
                    ours
                  elsif ours == base
                    theirs
                  else
                    nil
                  end
        divergent = ours != theirs && ours != base && theirs != base
        if divergent
          if resolved = Merge.merge_blob(self, base, ours, theirs, max_object_bytes, check)
            desired = resolved[0]
            transferred += resolved[1].bytesize
            raise Error.new("Git staged-only cleanup byte budget exceeded") if transferred > max_total_bytes
            divergent = false
          end
        end
        raise Error.new("Git staged-only cleanup conflict at #{path}") if divergent
        cleanup[path] = desired if desired
      end
      Checkout.require_tree_paths!(cleanup.keys, "Git staged-only cleanup")
      {cleanup, transferred}
    end

    private def stash_worktree_leaf?(path : String, max_bytes : Int32, *,
                                     allow_directory_missing : Bool,
                                     check : Proc(Nil)?) : {Checkout::FileState, String}?
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      parent = @root
      path.split('/')[0...-1].each do |component|
        check.try &.call
        parent = File.join(parent, component)
        raise Error.new("Git stash worktree parent is a symlink") if File.symlink?(parent)
        return nil unless File.exists?(parent)
        raise Error.new("Git stash worktree parent is not a directory") unless Dir.exists?(parent) && File.realpath(parent) == parent
      end
      absolute = File.join(@root, path)
      if File.symlink?(absolute)
        raw = Checkout.symlink_target(@root, path, max_bytes)
        return {Checkout::FileState.new("120000", ObjectId.digest("blob", raw, @object_format)), raw}
      end
      return nil unless File.exists?(absolute)
      if Dir.exists?(absolute)
        return nil if allow_directory_missing
        raise Error.new("Git stash tracked worktree path became a directory")
      end
      raise Error.new("Git stash worktree leaf is unsupported") unless File.file?(absolute)
      mode, raw = checkout_working_regular(path, max_bytes) { check.try &.call }
      {Checkout::FileState.new(mode, ObjectId.digest("blob", raw, @object_format)), raw}
    end

    private def stash_verify_worktree_snapshot!(index : Array(Index::Entry),
                                                observed : Hash(String, Checkout::FileState), *,
                                                selected_paths : Set(String)?,
                                                max_object_bytes : Int32,
                                                check : Proc(Nil)?) : Nil
      indexed = index.map(&.path).to_set
      index.each do |entry|
        next if selected_paths && !selected_paths.includes?(entry.path)
        leaf = stash_worktree_leaf?(entry.path, max_object_bytes,
          allow_directory_missing: false, check: check)
        actual = leaf.try(&.[0])
        raise Error.new("Git stash worktree changed during save") unless actual == observed[entry.path]?
      end
      observed.each do |path, expected_state|
        next if indexed.includes?(path)
        leaf = stash_worktree_leaf?(path, max_object_bytes,
          allow_directory_missing: false, check: check)
        raise Error.new("Git stash excluded worktree path changed during save") unless leaf.try(&.[0]) == expected_state
      end
    end

    private def stash_write_tree(states : Hash(String, Checkout::FileState), *,
                                 max_object_bytes : Int32,
                                 check : Proc(Nil)?) : String
      builder = Index::TreeBuilder.new
      states.keys.sort.each do |path|
        state = states[path]
        builder.add(Index::Entry.new(path, state.mode, state.oid, 0, false, false))
      end
      builder.write(self, max_bytes: max_object_bytes.to_i64, check: check)
    end
  end
end
