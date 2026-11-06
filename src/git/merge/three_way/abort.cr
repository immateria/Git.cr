module Git
  class Repository
    # Abort an incomplete native merge by restoring ordinary tracked content
    # and the entire index to the still-current original HEAD. This is an
    # explicitly destructive operation on merge-touched tracked paths.
    protected def merge_abort(*, max_object_bytes : Int32 = 8_388_608,
                              max_index_bytes : Int32 = 8_388_608,
                              max_total_bytes : Int64 = 67_108_864,
                              max_entries : Int32 = 10_000,
                              check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      branch, ours_oid, theirs_oid = merge_state? || raise Error.new("no Git merge in progress")
      raise Error.new("Git merge abort HEAD changed") unless head_ref_and_oid == {branch, ours_oid}
      ours_tree = read_commit(ours_oid, max_bytes: max_object_bytes, check: check).tree
      theirs_tree = read_commit(theirs_oid, max_bytes: max_object_bytes, check: check).tree
      ours = Checkout.tree_files(self, ours_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      theirs = Checkout.tree_files(self, theirs_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      current = @index.entries(max_index_bytes) { check.try &.call }
      manifest_admin = DescriptorPath::Directory.open(@git_dir)
      begin
        relocation_data = Merge::Recovery.read(manifest_admin, "CRYSTAL_MERGE_PATHS", max_index_bytes)
      ensure
        manifest_admin.close
      end
      receipt = Merge::Recovery.decode(relocation_data, ours_oid, theirs_oid,
        @object_format, max_index_bytes, max_entries)
      allowed = (ours.keys + theirs.keys + receipt.paths + receipt.outputs.keys).uniq
      raise Error.new("Git merge abort refuses unrelated staged paths") if current.any? { |entry| !allowed.includes?(entry.path) }
      Checkout.require_tree_paths!(ours.keys, "Git merge abort target")
      view = Merge::Recovery.observe(self, current, ours, receipt,
        max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
      view.preflight!(@root, ours.keys, max_entries)
      desired = IndexRestore.source_entries(self, ours_tree,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
      edits = IndexRestore.edits(current, desired, nil)
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries * 3, check: check)
      snapshot = @index.snapshot_checksum(max_index_bytes)
      observations = view.observations
      writes = [] of Checkout::Write
      removals = [] of {String, Checkout::FileState}
      total = view.bytes
      observations.keys.sort.each do |path|
        check.try &.call
        observed = observations[path]
        if goal = ours[path]?
          next if goal == observed
          kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git merge abort source not blob") unless kind == "blob"
          total += raw.bytesize
          raise Error.new("Git merge abort total byte budget exceeded") if total > max_total_bytes
          writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
        elsif observed_state = observed
          removals << {path, observed_state}
        end
      end
      write_paths = writes.map(&.path)
      blocking_removals, trailing_removals = removals.partition do |path, _state|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = view.transition_directories(ours.keys)
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
          raise Error.new("Git merge abort recovery metadata changed") unless Merge::Recovery.read(admin, "CRYSTAL_MERGE_PATHS", max_index_bytes) == relocation_data
          raise Error.new("Git merge abort state changed") unless head_ref_and_oid == {branch, ours_oid} &&
                                                                  merge_state? == {branch, ours_oid, theirs_oid} &&
                                                                  @index.snapshot_checksum(max_index_bytes) == snapshot
        end
        guard.call
        view.preflight!(@root, ours.keys, max_entries)
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
          raise Error.new("Git merge abort admin directory changed") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        cleanup_started = true
        merge_clear_metadata!(admin, branch, ours_oid, theirs_oid)
        changed
      rescue ex
        raise Merge::PartialPublication.new(changed.dup, index_published, ex) if started || index_published || cleanup_started
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
  end
end
