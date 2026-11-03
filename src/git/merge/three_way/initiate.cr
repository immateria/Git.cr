module Git
  class Repository
    # Bounded three-way tree merge for ordinary regular files with exactly
    # one merge base. Identical/one-sided changes are resolved; concurrent
    # changes to the same path become Git's staged 1/2/3 conflicts. No rename
    # detection or overlapping-line auto merge yet. Conflicts get basic text
    # markers when safe, otherwise the ours blob stays in the worktree.
    # A clean merge is committed with two parents. Unresolved merges keep
    # MERGE_HEAD and must be completed or aborted explicitly.
    def merge(source : String, *, author : Signature, committer : Signature,
              message : String, max_history_nodes : Int32 = 16_384,
              max_object_bytes : Int32 = 8_388_608,
              max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864,
              max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Merge::Result
      require_worktree!
      raise ArgumentError.new("invalid Git three-way merge budgets") if max_history_nodes < 1 || max_object_bytes < 128 ||
                                                                        max_index_bytes < 128 || max_total_bytes < max_object_bytes ||
                                                                        max_entries < 1 || max_entries > @max_search_entries
      raise Error.new("Git merge message invalid") if message.empty? || message.includes?('\0') || message.bytesize > 65_536
      check!
      raise Error.new("Git three-way merge unsupported with linked worktrees") unless @git_dir == @common &&
                                                                                      (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      branch, old_oid = head_ref_and_oid
      raise Error.new("Git three-way merge requires an existing symbolic branch") unless branch &&
                                                                                         branch.starts_with?("refs/heads/") && old_oid
      raise Error.new("Git merge is already in progress") if merge_state?
      raise Error.new("Git merge refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git merge refuses in-progress rebase") if rebase_state?
      raise Error.new("Git merge state files already exist") if merge_metadata_exists?
      target = History.resolve_commit(self, source, max_object_bytes, check)
      bases = merge_bases(old_oid, target, max_nodes: max_history_nodes,
        max_commit_bytes: max_object_bytes, check: check)
      raise Error.new("Git three-way merge requires exactly one common ancestor") unless bases.size == 1
      return Merge::Result.new(old_oid, target, bases[0], [] of String, [] of String, nil) if target == old_oid || bases == [target]
      if bases == [old_oid]
        fast = fast_forward(source, max_history_nodes: max_history_nodes,
          max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
          max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
        return Merge::Result.new(old_oid, target, old_oid, fast.changed_paths, [] of String, target)
      end
      base_oid = bases[0]
      orig_tree = read_commit(old_oid, max_bytes: max_object_bytes, check: check).tree
      theirs_tree = read_commit(target, max_bytes: max_object_bytes, check: check).tree
      base_tree = read_commit(base_oid, max_bytes: max_object_bytes, check: check).tree
      ours = Checkout.tree_files(self, orig_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      theirs = Checkout.tree_files(self, theirs_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      base = Checkout.tree_files(self, base_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
      names = (ours.keys + theirs.keys + base.keys).uniq.sort
      raise Error.new("Git merge entry budget exceeded") if names.size > max_entries
      Checkout.require_tree_paths!(ours.keys, "Git ours tree")
      Checkout.require_tree_paths!(theirs.keys, "Git theirs tree")
      Checkout.require_tree_paths!(base.keys, "Git base tree")
      rename_plan = Merge.rename_plan(base, ours, theirs)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git merge requires index equal to HEAD") unless Merge.index_matches_head?(current, ours)
      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
      plan = Merge.plan_files(self, names, base, ours, theirs, rename_plan,
        marker_label: source, operation: "Git merge",
        max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
      edits, writes, conflicts = {plan.edits, plan.writes, plan.conflicts}
      final_paths = plan.final_paths(current)
      if Checkout.path_collision(final_paths)
        raise Error.new("Git merge divergent file/directory conflict unsupported")
      end
      Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
        max_entries: max_entries)
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries * 3, check: check)
      blocking_removals, trailing_removals = plan.partition_removals
      transition_dirs = Checkout.transition_directories(ours.keys, final_paths)
      # Verify that symlink targets are publishable before any MERGE_HEAD or
      # worktree mutation is attempted, rather than leaving a stranded merge.
      plan.validate_symlinks!
      snapshot = @index.snapshot_checksum(max_index_bytes)
      admin = DescriptorPath::Directory.open(@git_dir)
      lock = nil.as(IO::FileDescriptor?)
      started = false
      index_published = false
      changed_paths = [] of String
      begin
        lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard = -> do
          check.try &.call
          raise Error.new("Git merge HEAD changed") unless head_ref_and_oid == {branch, old_oid}
          raise Error.new("Git merge index changed") unless @index.snapshot_checksum(max_index_bytes) == snapshot
        end
        guard.call
        Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
        Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
          max_entries: max_entries)
        started = true
        merge_write_metadata!(admin, branch, old_oid, target, message)
        if planned = image
          raise Error.new("Git merge index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          lock.write(planned.data.to_slice)
          lock.flush
          lock.fsync
        end
        blocking_removals.each do |path, state|
          Checkout.remove(@root, path, state, format: @object_format, check: guard)
          changed_paths << path
        end
        transition_dirs.each do |directory|
          Checkout.remove_empty_directory(@root, directory, check: guard)
        end
        writes.each_with_index do |write, sequence|
          Checkout.write(@root, write, sequence, expected_old: ours[write.path]?,
            format: @object_format, check: guard)
          changed_paths << write.path
        end
        trailing_removals.each do |path, state|
          Checkout.remove(@root, path, state, format: @object_format, check: guard)
          changed_paths << path
        end
        if image
          guard.call
          raise Error.new("Git merge admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
      rescue ex
        raise Merge::PartialPublication.new(changed_paths.dup, index_published, ex) if started
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
      committed = nil.as(String?)
      if conflicts.empty?
        begin
          committed = merge_continue(author: author, committer: committer,
            max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
        rescue ex : Merge::PartialCommit
          raise ex
        rescue ex
          raise Merge::PartialPublication.new(changed_paths.dup, index_published, ex)
        end
      end
      Merge::Result.new(old_oid, target, base_oid, changed_paths, conflicts, committed)
    end
  end
end
