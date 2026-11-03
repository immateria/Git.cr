module Git
  class Repository
    # Abort an incomplete native merge by restoring ordinary tracked content
    # and the entire index to the still-current original HEAD. This is an
    # explicitly destructive operation on merge-touched tracked paths.
    def merge_abort(*, max_object_bytes : Int32 = 8_388_608,
                    max_index_bytes : Int32 = 8_388_608,
                    max_total_bytes : Int64 = 67_108_864,
                    max_entries : Int32 = 10_000,
                    check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      branch, ours_oid, theirs_oid = merge_state? || raise Error.new("no Git merge in progress")
      raise Error.new("Git merge abort HEAD changed") unless head == {branch, ours_oid}
      ours_tree = commit(ours_oid, max_object_bytes) { check.try &.call }.tree
      theirs_tree = commit(theirs_oid, max_object_bytes) { check.try &.call }.tree
      ours = Checkout.tree_files(self, ours_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      theirs = Checkout.tree_files(self, theirs_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      current = @index.entries(max_index_bytes) { check.try &.call }
      # Never delete unrelated files staged by the caller while resolving a
      # conflict. Such paths did not belong to this merge's source trees.
      names = (ours.keys + theirs.keys).uniq.sort
      raise Error.new("Git merge abort refuses unrelated staged paths") if current.any? { |entry| !names.includes?(entry.path) }
      raise Error.new("Git merge abort path budget exceeded") if names.size > max_entries
      Checkout.require_compatible_paths!(names, names)
      desired = IndexRestore.source_entries(self, ours_tree, max_object_bytes: max_object_bytes,
        max_entries: max_entries, check: check)
      edits = IndexRestore.edits(current, desired, nil)
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries, check: check)
      snapshot = @index.snapshot_checksum(max_index_bytes)
      writes = [] of Checkout::Write
      observations = {} of String => Checkout::FileState?
      removals = [] of {String, Checkout::FileState}
      total = 0_i64
      names.each do |path|
        check.try &.call
        absolute = File.join(@root, path)
        parent = @root
        path.split('/')[0...-1].each do |part|
          parent = File.join(parent, part)
          raise Error.new("Git merge abort symlinked parent") if File.symlink?(parent)
          raise Error.new("Git merge abort parent not directory") if File.exists?(parent) && !Dir.exists?(parent)
        end
        observed = nil.as(Checkout::FileState?)
        if File.exists?(absolute) || File.symlink?(absolute)
          mode, raw = if File.symlink?(absolute)
                        {"120000", Checkout.symlink_target(@root, path, max_object_bytes)}
                      else
                        raise Error.new("Git merge abort refuses nonregular leaf") unless File.file?(absolute)
                        checkout_working_regular(path, max_object_bytes) { check.try &.call }
                      end
          total += raw.bytesize
          raise Error.new("Git merge abort total byte budget exceeded") if total > max_total_bytes
          observed = Checkout::FileState.new(mode, ObjectId.digest("blob", raw, @object_format))
        end
        observations[path] = observed
        if goal = ours[path]?
          next if goal == observed
          kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git merge abort source not blob") unless kind == "blob"
          total += raw.bytesize
          raise Error.new("Git merge abort total byte budget exceeded") if total > max_total_bytes
          writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
        elsif state = observed
          removals << {path, state}
        end
      end
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
          raise Error.new("Git merge abort state changed") unless head == {branch, ours_oid} &&
                                                                  merge_state? == {branch, ours_oid, theirs_oid} &&
                                                                  @index.snapshot_checksum(max_index_bytes) == snapshot
        end
        guard.call
        if planned = image
          lock.write(planned.data.to_slice)
          lock.flush
          lock.fsync
        end
        writes.each_with_index do |write, sequence|
          started = true
          Checkout.write(@root, write, sequence, expected_old: observations[write.path],
            format: @object_format, check: guard)
          changed << write.path
        end
        removals.each do |path, previous|
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
