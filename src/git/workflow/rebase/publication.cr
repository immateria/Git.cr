module Git
  class Repository
    private def rebase_move_branch!(state : Rebase::State, from_oid : String, to_oid : String, *,
                                    log : References::LogEntry,
                                    max_object_bytes : Int32, max_index_bytes : Int32,
                                    max_total_bytes : Int64, max_entries : Int32,
                                    check : Proc(Nil)?) : Array(String)
      return [] of String if from_oid == to_oid
      raise Error.new("Git rebase move state changed") unless rebase_state? == state
      raise Error.new("Git rebase move HEAD changed") unless head_ref_and_oid == {state.branch, from_oid}
      old_tree = read_commit(from_oid, max_bytes: max_object_bytes, check: check).tree
      target_tree = read_commit(to_oid, max_bytes: max_object_bytes, check: check).tree
      old = Checkout.tree_files(self, old_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      desired = Checkout.tree_files(self, target_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git rebase move requires index equal to HEAD") unless current.size == old.size && current.all? do |entry|
                                                                               entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                               old[entry.path]?.try { |value| value.mode == entry.mode && value.oid == entry.oid } == true
                                                                             end
      Checkout.require_tree_paths!(old.keys, "Git rebase predecessor")
      Checkout.require_tree_paths!(desired.keys, "Git rebase destination")
      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
      Checkout.require_transition_destinations!(@root, old.keys, desired.keys,
        max_entries: max_entries)
      changed = (old.keys + desired.keys).uniq.sort.select { |path| old[path]? != desired[path]? }
      raise Error.new("Git rebase move entry budget exceeded") if changed.size > max_entries
      edits = [] of Index::Edit
      writes = [] of Checkout::Write
      removes = [] of String
      transferred = 0_i64
      changed.each do |path|
        check.try &.call
        if next_entry = desired[path]?
          kind, raw = object(next_entry.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git rebase move entry is not a blob") unless kind == "blob"
          transferred += raw.bytesize
          raise Error.new("Git rebase move total byte budget exceeded") if transferred > max_total_bytes
          writes << Checkout::Write.new(path, next_entry.mode, next_entry.oid, raw)
          edits << Index::Put.new(path, next_entry.mode, next_entry.oid)
        else
          removes << path
          edits << Index::Remove.new(path)
        end
      end
      image = edits.empty? ? nil : @index.prepare_changes(edits,
        max_bytes: max_index_bytes, max_entries: max_entries, check: check)
      write_paths = writes.map(&.path)
      blocking_removes, trailing_removes = removes.partition do |path|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = Checkout.transition_directories(old.keys, desired.keys)
      checksum = @index.snapshot_checksum(max_index_bytes)
      admin = DescriptorPath::Directory.open(@git_dir)
      index_lock = nil.as(IO::FileDescriptor?)
      started = false
      ref_published = false
      index_published = false
      changed_paths = [] of String
      begin
        index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard = -> do
          check.try &.call
          raise Error.new("Git rebase move state changed") unless rebase_state? == state
          raise Error.new("Git rebase move HEAD changed") unless head_ref_and_oid == {state.branch, from_oid}
          raise Error.new("Git rebase move index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
        end
        guard.call
        Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
        Checkout.require_transition_destinations!(@root, old.keys, desired.keys,
          max_entries: max_entries)
        if planned = image
          raise Error.new("Git rebase move index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          index_lock.write(planned.data.to_slice)
          index_lock.flush
          index_lock.fsync
        end
        blocking_removes.each do |path|
          started = true
          Checkout.remove(@root, path, old[path], format: @object_format, check: guard)
          changed_paths << path
        end
        transition_dirs.each do |directory|
          started = true
          Checkout.remove_empty_directory(@root, directory, check: guard)
        end
        writes.each_with_index do |write, sequence|
          started = true
          Checkout.write(@root, write, sequence, expected_old: old[write.path]?,
            format: @object_format, check: guard)
          changed_paths << write.path
        end
        trailing_removes.each do |path|
          started = true
          Checkout.remove(@root, path, old[path], format: @object_format, check: guard)
          changed_paths << path
        end
        guard.call
        update_ref(state.branch, to_oid, expected_oid: from_oid, log: log,
          max_object_bytes: max_object_bytes, check: guard)
        ref_published = true
        if planned = image
          check.try &.call
          raise Error.new("Git rebase move index image diverged after ref publication") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          raise Error.new("Git rebase move admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        changed_paths
      rescue ex
        if started || ref_published || index_published
          raise Rebase::PartialPublication.new(changed_paths.dup, ref_published, index_published, ex)
        end
        raise ex
      ensure
        if io = index_lock
          if admin.same_inode?("index.lock", io)
            admin.unlink("index.lock")
            admin.sync
          end
          io.close unless io.closed?
        end
        admin.close
      end
    end
  end
end
