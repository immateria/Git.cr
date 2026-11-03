module Git
  class Repository
    # Checkout a named local branch in a clean, ordinary working repository.
    # All files must be regular, staged state must equal HEAD and tracked
    # worktree files must be unchanged. Clean file/directory transitions are
    # planned explicitly and refuse untracked content before publication.
    # Worktree, index and HEAD are published in that order, not atomically.
    def checkout_branch(name : String, *, max_blob_bytes : Int32 = 8_388_608,
                        max_index_bytes : Int32 = 8_388_608,
                        max_total_bytes : Int64 = 67_108_864,
                        max_files : Int32 = 10_000,
                        check : Proc(Nil)? = nil) : Checkout::Result
      require_worktree!
      raise Error.new("Git checkout refuses in-progress merge") if merge_state?
      raise Error.new("Git checkout refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git checkout refuses in-progress rebase") if rebase_state?
      raise ArgumentError.new("invalid Git checkout budgets") if max_blob_bytes < 128 || max_index_bytes < 128 ||
                                                                 max_total_bytes < max_blob_bytes || max_files < 1 || max_files > @max_search_entries
      check!
      raise Error.new("Git checkout unsupported with linked worktrees") unless @git_dir == @common &&
                                                                               (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      target_ref = new_branch_ref(name)
      oid = resolve_ref?(target_ref) || raise Error.new("Git checkout branch missing")
      target = History.resolve_commit(self, target_ref, max_blob_bytes, check)
      raise Error.new("Git checkout branch does not resolve to a direct commit") unless target == oid
      original_ref, original_oid = head
      return Checkout::Result.new(target_ref, target, [] of String) if original_ref == target_ref
      old_tree = original_oid ? commit(original_oid, max_blob_bytes) { check.try &.call }.tree : nil
      next_tree = commit(target, max_blob_bytes) { check.try &.call }.tree
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git checkout index entry budget exceeded") if current.size > max_files
      original = old_tree ? Checkout.tree_files(self, old_tree, max_object_bytes: max_blob_bytes, max_files: max_files, check: check) : {} of String => Checkout::FileState
      desired = Checkout.tree_files(self, next_tree, max_object_bytes: max_blob_bytes, max_files: max_files, check: check)
      raise Error.new("Git checkout requires index equal to HEAD") unless current.size == original.size && current.all? do |entry|
                                                                            entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                            original[entry.path]?.try { |value| value.mode == entry.mode && value.oid == entry.oid } == true
                                                                          end
      Checkout.require_tree_paths!(original.keys, "Git checkout predecessor")
      Checkout.require_tree_paths!(desired.keys, "Git checkout destination")
      Checkout.require_clean!(self, current, max_blob_bytes: max_blob_bytes,
        max_total_bytes: max_total_bytes, check: check)
      Checkout.require_transition_destinations!(@root, original.keys, desired.keys,
        max_entries: max_files)
      changed = (original.keys + desired.keys).uniq.sort.select { |path| original[path]? != desired[path]? }
      raise Error.new("Git checkout entry budget exceeded") if changed.size > max_files
      edits = [] of Index::Edit
      writes = [] of Checkout::Write
      removes = [] of String
      transferred = 0_i64
      changed.each do |path|
        check.try &.call
        if next_entry = desired[path]?
          kind, raw = @object_database.object(next_entry.oid, max_blob_bytes) { check.try &.call }
          raise Error.new("Git checkout entry is not a blob") unless kind == "blob"
          transferred += raw.bytesize
          raise Error.new("Git checkout total byte budget exceeded") if transferred > max_total_bytes
          writes << Checkout::Write.new(path, next_entry.mode, next_entry.oid, raw)
          edits << Index::Put.new(path, next_entry.mode, next_entry.oid)
        else
          removes << path
          edits << Index::Remove.new(path)
        end
      end
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_files, check: check)
      write_paths = writes.map(&.path)
      blocking_removes, trailing_removes = removes.partition do |path|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = Checkout.transition_directories(original.keys, desired.keys)
      original_checksum = @index.snapshot_checksum(max_index_bytes)
      raise Error.new("Git checkout index changed during planning") if image &&
                                                                       @index.image_state(image, max_bytes: max_index_bytes) != :before
      admin = DescriptorPath::Directory.open(@git_dir)
      index_lock = nil.as(IO::FileDescriptor?)
      head_lock = nil.as(IO::FileDescriptor?)
      changed_paths = [] of String
      index_published = false
      publication_started = false
      begin
        index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        head_lock = admin.open_file("HEAD.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        head_original_io = admin.open_file("HEAD", LibC::O_RDONLY)
        head_original = begin
          head_original_io.gets_to_end
        ensure
          head_original_io.close
        end
        raise Error.new("Git checkout HEAD changed before publication") unless head == {original_ref, original_oid}
        raise Error.new("Git checkout index changed before publication") unless @index.snapshot_checksum(max_index_bytes) == original_checksum
        raise Error.new("Git checkout target branch changed") unless resolve_ref?(target_ref) == oid
        Checkout.require_clean!(self, current, max_blob_bytes: max_blob_bytes,
          max_total_bytes: max_total_bytes, check: check)
        Checkout.require_transition_destinations!(@root, original.keys, desired.keys,
          max_entries: max_files)
        blocking_removes.each do |path|
          publication_started = true
          Checkout.remove(@root, path, original[path], format: @object_format, check: check)
          changed_paths << path
        end
        transition_dirs.each do |directory|
          publication_started = true
          Checkout.remove_empty_directory(@root, directory, check: check)
        end
        writes.each_with_index do |write, sequence|
          publication_started = true
          Checkout.write(@root, write, sequence, expected_old: original[write.path]?,
            format: @object_format, check: check)
          changed_paths << write.path
        end
        trailing_removes.each do |path|
          publication_started = true
          Checkout.remove(@root, path, original[path], format: @object_format, check: check)
          changed_paths << path
        end
        check.try &.call
        raise Error.new("Git checkout HEAD or branch changed") unless head == {original_ref, original_oid} && resolve_ref?(target_ref) == oid
        raise Error.new("Git checkout index changed") unless @index.snapshot_checksum(max_index_bytes) == original_checksum
        if selected = image
          raise Error.new("Git checkout index image diverged") unless @index.image_state(selected, max_bytes: max_index_bytes) == :before
          index_lock.not_nil!.write(selected.data.to_slice)
          index_lock.not_nil!.flush
          index_lock.not_nil!.fsync
          raise Error.new("Git checkout admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        head_lock.not_nil!.write("ref: #{target_ref}\n".to_slice)
        head_lock.not_nil!.flush
        head_lock.not_nil!.fsync
        readback = admin.open_file("HEAD", LibC::O_RDONLY)
        head_current = begin
          readback.gets_to_end
        ensure
          readback.close
        end
        raise Error.new("Git checkout HEAD changed") unless head_current == head_original
        raise Error.new("Git checkout admin directory replaced") unless admin.attached_at?(@git_dir)
        admin.rename("HEAD.lock", "HEAD")
        admin.sync
        Checkout::Result.new(target_ref, target, changed_paths)
      rescue ex
        if publication_started || index_published
          raise Checkout::PartialPublication.new(changed_paths.dup, index_published, ex)
        end
        raise ex
      ensure
        if io = head_lock
          if admin.same_inode?("HEAD.lock", io)
            admin.unlink("HEAD.lock")
            admin.sync
          end
          io.close unless io.closed?
        end
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
