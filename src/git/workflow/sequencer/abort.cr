module Git
  class Repository
    # Restore the original HEAD tree/index/worktree and clear single-item
    # sequencer metadata. Resolution-time unrelated staged paths are refused.
    # D/F transitions are restored with the same collision planner used by
    # checkout and merge; untracked content is never recursively removed.
    def sequencer_abort(*, max_object_bytes : Int32 = 8_388_608,
                        max_index_bytes : Int32 = 8_388_608,
                        max_total_bytes : Int64 = 67_108_864,
                        max_entries : Int32 = 10_000,
                        check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      state = sequencer_state? || raise Error.new("no Git sequencer operation in progress")
      raise Error.new("Git sequencer abort HEAD changed") unless head == {state.branch, state.original_head}
      original_tree = commit(state.original_head, max_object_bytes) { check.try &.call }.tree
      original = Checkout.tree_files(self, original_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      source = Sequencer.read_source(self, state.source, max_object_bytes, check)
      source_files = Checkout.tree_files(self, source.tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      parent_files = if parent_oid = state.parent
                       parent_tree = commit(parent_oid, max_object_bytes) { check.try &.call }.tree
                       Checkout.tree_files(self, parent_tree, max_object_bytes: max_object_bytes,
                         max_files: max_entries, check: check, allow_symlinks: true)
                     else
                       {} of String => Checkout::FileState
                     end
      allowed = (original.keys + source_files.keys + parent_files.keys).uniq
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git sequencer abort refuses unrelated staged paths") if current.any? { |entry| !allowed.includes?(entry.path) }
      current_paths = current.map(&.path).uniq
      raise Error.new("Git sequencer abort path budget exceeded") if (original.keys + current_paths).uniq.size > max_entries
      Checkout.require_tree_paths!(original.keys, "Git sequencer abort target")
      Checkout.require_tree_paths!(current_paths, "Git sequencer abort current index")
      Checkout.require_transition_destinations!(@root, current_paths, original.keys,
        max_entries: max_entries)
      desired = IndexRestore.source_entries(self, original_tree,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
      edits = IndexRestore.edits(current, desired, nil)
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries * 3, check: check)
      snapshot = @index.snapshot_checksum(max_index_bytes)
      names = (original.keys + current_paths).uniq.sort
      observations = {} of String => Checkout::FileState?
      writes = [] of Checkout::Write
      removals = [] of {String, Checkout::FileState}
      total = 0_i64
      current_prefixes = Checkout.path_prefixes(current_paths)
      names.each do |path|
        check.try &.call
        absolute = File.join(@root, path)
        observed = nil.as(Checkout::FileState?)
        if current_prefixes.includes?(path) && Dir.exists?(absolute) && !File.symlink?(absolute)
          # Structural directory in the current tracked view; descendant leaves
          # are observed independently and removed before a target file write.
        elsif File.exists?(absolute) || File.symlink?(absolute)
          mode, raw = if File.symlink?(absolute)
                        {"120000", Checkout.symlink_target(@root, path, max_object_bytes)}
                      else
                        raise Error.new("Git sequencer abort refuses nonregular leaf") unless File.file?(absolute)
                        checkout_working_regular(path, max_object_bytes) { check.try &.call }
                      end
          total += raw.bytesize
          raise Error.new("Git sequencer abort total byte budget exceeded") if total > max_total_bytes
          observed = Checkout::FileState.new(mode, ObjectId.digest("blob", raw, @object_format))
        end
        observations[path] = observed
        if goal = original[path]?
          next if goal == observed
          kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git sequencer abort source not blob") unless kind == "blob"
          total += raw.bytesize
          raise Error.new("Git sequencer abort total byte budget exceeded") if total > max_total_bytes
          writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
        elsif observed_state = observed
          removals << {path, observed_state}
        end
      end
      write_paths = writes.map(&.path)
      blocking_removals, trailing_removals = removals.partition do |path, _state|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = Checkout.transition_directories(current_paths, original.keys)
      admin = DescriptorPath::Directory.open(@git_dir)
      lock = nil.as(IO::FileDescriptor?)
      started = false
      index_published = false
      cleanup_started = false
      changed = [] of String
      begin
        lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard = -> do
          check.try &.call
          raise Error.new("Git sequencer abort state changed") unless head == {state.branch, state.original_head} &&
                                                                      sequencer_state? == state &&
                                                                      @index.snapshot_checksum(max_index_bytes) == snapshot
        end
        guard.call
        Checkout.require_transition_destinations!(@root, current_paths, original.keys,
          max_entries: max_entries)
        if planned = image
          lock.write(planned.data.to_slice)
          lock.flush
          lock.fsync
        end
        blocking_removals.each do |path, previous|
          started = true
          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
          changed << path
        end
        transition_dirs.each do |directory|
          started = true
          Checkout.remove_empty_directory(@root, directory, check: guard)
        end
        writes.each_with_index do |write, sequence|
          started = true
          Checkout.write(@root, write, sequence, expected_old: observations[write.path],
            format: @object_format, check: guard)
          changed << write.path
        end
        trailing_removals.each do |path, previous|
          started = true
          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
          changed << path
        end
        if image
          guard.call
          raise Error.new("Git sequencer abort admin directory changed") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        cleanup_started = true
        sequencer_clear_metadata!(admin, state)
        changed
      rescue ex
        if started || index_published || cleanup_started
          raise Sequencer::PartialPublication.new(changed.dup, index_published, ex)
        end
        raise ex
      ensure
        if io = lock
          if admin.same_inode?("index.lock", io)
            admin.unlink("index.lock")
            admin.sync
          end
          io.close unless io.closed?
        end
        admin.close
      end
    end

    # For the current single-item sequencer, skip restores the pre-operation
    # state and clears metadata. A later multi-item sequencer can advance its
    # todo list on top of this same public operation.
    def sequencer_skip(**options) : Array(String)
      sequencer_abort(**options)
    end

    def cherry_pick_abort(**options) : Array(String)
      state = sequencer_state? || raise Error.new("no Git cherry-pick in progress")
      raise Error.new("Git sequencer operation is not a cherry-pick") unless state.kind.cherry_pick?
      sequencer_abort(**options)
    end

    def revert_abort(**options) : Array(String)
      state = sequencer_state? || raise Error.new("no Git revert in progress")
      raise Error.new("Git sequencer operation is not a revert") unless state.kind.revert?
      sequencer_abort(**options)
    end
  end
end
