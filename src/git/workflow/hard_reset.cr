module Git
  class Repository
    # Explicit hard reset of a symbolic branch or detached HEAD in a
    # regular-only worktree. This overwrites dirty tracked bytes and discards
    # staged changes. It refuses untracked target collisions, D/F transitions,
    # symlinks, gitlinks, sparse paths and a linked-worktree configuration.
    # Changes to worktree, ref and index are NOT an atomic Git transaction.
    protected def reset_head_hard(source : String = "HEAD", *,
                                  log : References::LogEntry? = nil, config : Config? = nil,
                                  max_object_bytes : Int32 = 8_388_608,
                                  max_index_bytes : Int32 = 8_388_608,
                                  max_total_bytes : Int64 = 67_108_864,
                                  max_entries : Int32 = 10_000,
                                  clean_only : Bool = false,
                                  check : Proc(Nil)? = nil) : Reset::Result
      require_worktree!
      raise Error.new("Git hard reset refuses in-progress merge") if merge_state?
      raise Error.new("Git hard reset refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git hard reset refuses in-progress rebase") if rebase_state?
      raise ArgumentError.new("invalid Git hard reset budgets") if max_object_bytes < 128 ||
                                                                   max_index_bytes < 128 || max_total_bytes < max_object_bytes ||
                                                                   max_entries < 1 || max_entries > @max_search_entries
      check!
      raise Error.new("Git hard reset unsupported with linked worktrees") unless @git_dir == @common &&
                                                                                 (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      reference, previous = head_ref_and_oid
      unless previous && (reference.nil? || reference.starts_with?("refs/heads/"))
        raise Error.new("Git hard reset requires an existing branch or detached HEAD")
      end
      target = History.resolve_commit(self, source, max_object_bytes, check)
      old_tree = read_commit(previous, max_bytes: max_object_bytes, check: check).tree
      target_tree = read_commit(target, max_bytes: max_object_bytes, check: check).tree
      old = Checkout.tree_files(self, old_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check)
      desired = Checkout.tree_files(self, target_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check)
      index = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git hard reset index entry budget exceeded") if index.size > max_entries
      selected_config = config || self.config
      target_conversion = Conversion.new(self, config: selected_config, attribute_tree: target_tree,
        max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
      source_conversion = if clean_only
                            Conversion.new(self, config: selected_config,
                              max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
                          end
      index.each do |entry|
        raise Error.new("Git hard reset requires an ordinary resolved index") unless entry.stage == 0 &&
                                                                                     !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                                     {"100644", "100755"}.includes?(entry.mode)
      end
      if clean_only
        raise Error.new("Git clean-only reset requires index equal to HEAD") unless index.size == old.size && index.all? do |entry|
                                                                                      old[entry.path]?.try { |state| state.mode == entry.mode && state.oid == entry.oid } == true
                                                                                    end
        Checkout.require_clean!(self, index, max_blob_bytes: max_object_bytes,
          max_total_bytes: max_total_bytes, check: check, conversion: source_conversion)
      end
      index_by_path = {} of String => Index::Entry
      index.each { |entry| index_by_path[entry.path] = entry }
      index_time = @index.modified_at
      verified = Set(String).new
      tracked = (old.keys + index.map(&.path)).uniq
      Checkout.require_compatible_paths!(tracked, desired.keys)
      names = (tracked + desired.keys).uniq.sort
      raise Error.new("Git hard reset entry budget exceeded") if names.size > max_entries
      edits = IndexRestore.edits(index, IndexRestore.source_entries(self, target_tree,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check), nil)
      changed_index_paths = edits.map(&.path)
      checksum = @index.snapshot_checksum(max_index_bytes)
      observed = {} of String => Checkout::FileState?
      writes = [] of Checkout::Write
      removals = [] of {String, Checkout::FileState}
      transferred = 0_i64
      names.each do |path|
        check.try &.call
        # Never silently replace a newly tracked path that already exists
        # outside both HEAD and the index, including an ignored file.
        Checkout.require_free_destination!(@root, path) unless tracked.includes?(path)
        absolute = File.join(@root, path)
        indexed = index_by_path[path]?
        stat_clean = indexed ? @worktree.stat_unchanged?(indexed, true, index_time, verified) { check.try &.call } : false
        current = nil.as(Checkout::FileState?)
        clean_current = nil.as(Checkout::FileState?)
        if tracked.includes?(path)
          parent = @root
          path.split('/')[0...-1].each do |component|
            parent = File.join(parent, component)
            raise Error.new("Git hard reset symlinked parent") if File.symlink?(parent)
            if File.exists?(parent)
              raise Error.new("Git hard reset blocked parent") unless Dir.exists?(parent) && File.realpath(parent) == parent
            end
          end
          raise Error.new("Git hard reset refuses symlinked tracked file") if File.symlink?(absolute)
          if File.exists?(absolute)
            raise Error.new("Git hard reset tracked path is not regular") unless File.file?(absolute)
            mode, data = checkout_working_regular(path, max_object_bytes) { check.try &.call }
            transferred += data.bytesize
            raise Error.new("Git hard reset total byte budget exceeded") if transferred > max_total_bytes
            current = Checkout::FileState.new(mode, ObjectId.digest("blob", data, @object_format))
            if source_conversion
              canonical = source_conversion.clean(path, data, index_oid: indexed.try(&.oid))
              clean_current = Checkout::FileState.new(mode, ObjectId.digest("blob", canonical, @object_format))
            end
          end
        end
        if clean_only && old[path]? != clean_current
          raise Error.new("Git clean-only reset refuses dirty tracked files")
        end
        observed[path] = current
        if goal = desired[path]?
          next if (clean_only || stat_clean) && indexed && goal.mode == indexed.mode && goal.oid == indexed.oid
          kind, bytes = object(goal.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git hard reset target not a blob") unless kind == "blob"
          data = target_conversion.checkout(path, bytes)
          transferred += data.bytesize
          raise Error.new("Git hard reset total byte budget exceeded") if transferred > max_total_bytes
          output = Checkout::FileState.new(goal.mode, ObjectId.digest("blob", data, @object_format))
          if !clean_only && indexed && (recorded = indexed.stat) && recorded.size != 0 &&
             recorded.size != data.bytesize && !changed_index_paths.includes?(path)
            # A reset can materialize different EOL bytes for the same blob.
            # Do not retain the old size, or capture a newer unverified stat.
            edits << Index::InvalidateStat.new(path)
          end
          next if output == current
          writes << Checkout::Write.new(path, goal.mode, goal.oid, data)
        elsif actual = current
          removals << {path, actual}
        end
      end
      image = edits.empty? ? nil : @index.prepare_changes(edits,
        max_bytes: max_index_bytes, max_entries: max_entries, check: check)
      # The exclusive index lock serializes cooperative index changes until
      # the worktree, branch and prepared index image have been published.
      admin = DescriptorPath::Directory.open(@git_dir)
      locked = nil.as(IO::FileDescriptor?)
      worktree_started = false
      changed_paths = [] of String
      ref_published = false
      index_published = false
      begin
        locked = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard = -> do
          check.try &.call
          raise Error.new("Git hard reset HEAD changed") unless head_ref_and_oid == {reference, previous}
          raise Error.new("Git hard reset index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
        end
        guard.call
        if clean_only
          Checkout.require_clean!(self, index, max_blob_bytes: max_object_bytes,
            max_total_bytes: max_total_bytes, check: check, conversion: source_conversion)
        end
        if prepared = image
          raise Error.new("Git hard reset index image diverged") unless @index.image_state(prepared, max_bytes: max_index_bytes) == :before
          locked.write(prepared.data.to_slice)
          locked.flush
          locked.fsync
        end
        names.each { |path| Checkout.require_free_destination!(@root, path) unless tracked.includes?(path) }
        writes.each_with_index do |write, sequence|
          worktree_started = true
          Checkout.write(@root, write, sequence, expected_old: observed[write.path],
            format: @object_format, check: guard)
          changed_paths << write.path
        end
        removals.each do |path, actual|
          worktree_started = true
          Checkout.remove(@root, path, actual, format: @object_format, check: guard)
          changed_paths << path
        end
        guard.call
        write_orig_head(previous)
        if target != previous
          update_head_or_branch(reference, target, expected_oid: previous, log: log,
            max_object_bytes: max_object_bytes, check: guard)
          ref_published = true
        elsif entry = log
          append_head_log(previous, previous, entry)
        end
        if prepared = image
          check.try &.call
          raise Error.new("Git hard reset index changed after ref publication") unless @index.image_state(prepared, max_bytes: max_index_bytes) == :before
          raise Error.new("Git hard reset index directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        Reset::Result.new(reference, previous, target, Reset::Mode::Hard,
          changed_index_paths, changed_paths)
      rescue ex
        raise Reset::PartialPublication.new(ref_published, index_published, ex,
          changed_paths.dup) if worktree_started || ref_published || index_published
        raise ex
      ensure
        if io = locked
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
