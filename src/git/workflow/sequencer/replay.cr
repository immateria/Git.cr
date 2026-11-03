module Git
  class Repository
    private def sequencer_start(kind : Sequencer::Kind, source_expression : String, *,
                                committer : Signature, author : Signature?, message : String?,
                                mainline : Int32?, allow_empty : Bool,
                                max_object_bytes : Int32, max_index_bytes : Int32,
                                max_total_bytes : Int64, max_entries : Int32,
                                check : Proc(Nil)?, commit_result : Bool = true) : Sequencer::Result
      require_worktree!
      raise ArgumentError.new("invalid Git sequencer budgets") if max_object_bytes < 128 || max_index_bytes < 128 ||
                                                                  max_total_bytes < max_object_bytes || max_entries < 1 ||
                                                                  max_entries > @max_search_entries
      check!
      raise Error.new("Git sequencer unsupported with linked worktrees") unless @git_dir == @common &&
                                                                                (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      branch, old_oid = head_ref_and_oid
      raise Error.new("Git sequencer requires an existing symbolic branch") unless branch &&
                                                                                   branch.starts_with?("refs/heads/") && old_oid
      raise Error.new("Git sequencer refuses in-progress merge") if merge_state?
      raise Error.new("Git sequencer operation already in progress") if sequencer_state?
      if rebase = rebase_state?
        raise Error.new("Git sequencer refuses in-progress rebase") unless kind.rebase?
        raise Error.new("Git rebase sequencer HEAD changed") unless head_ref_and_oid == {rebase.branch, rebase.expected_head}
      elsif kind.rebase?
        raise Error.new("Git rebase state missing")
      end
      raise Error.new("Git sequencer state files already exist") if sequencer_metadata_exists?
      target = History.resolve_commit(self, source_expression, max_object_bytes, check)
      source = Sequencer.read_source(self, target, max_object_bytes, check)
      parent = Sequencer.selected_parent(source, mainline)
      operation_author = kind.revert? ? (author || raise Error.new("Git revert author required")) : source.author
      text = message || (kind.revert? ? Sequencer.default_revert_message(source) : source.message)
      validate_sequencer_message!(text)
      ours_tree = read_commit(old_oid, max_bytes: max_object_bytes, check: check).tree
      ours = Checkout.tree_files(self, ours_tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      source_files = Checkout.tree_files(self, source.tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      parent_files = if parent_oid = parent
                       parent_tree = read_commit(parent_oid, max_bytes: max_object_bytes, check: check).tree
                       Checkout.tree_files(self, parent_tree, max_object_bytes: max_object_bytes,
                         max_files: max_entries, check: check, allow_symlinks: true)
                     else
                       {} of String => Checkout::FileState
                     end
      base, theirs = kind.revert? ? {source_files, parent_files} : {parent_files, source_files}
      names = (ours.keys + theirs.keys + base.keys).uniq.sort
      raise Error.new("Git sequencer entry budget exceeded") if names.size > max_entries
      Checkout.require_tree_paths!(ours.keys, "Git sequencer HEAD tree")
      Checkout.require_tree_paths!(theirs.keys, "Git sequencer incoming tree")
      Checkout.require_tree_paths!(base.keys, "Git sequencer base tree")
      rename_plan = Merge.rename_plan(base, ours, theirs)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git sequencer requires index equal to HEAD") unless Merge.index_matches_head?(current, ours)
      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
      marker_label = kind.revert? ? "parent of #{source_expression}" : source_expression
      plan = Merge.plan_files(self, names, base, ours, theirs, rename_plan,
        marker_label: marker_label, operation: "Git sequencer",
        max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
      edits, writes, conflicts = {plan.edits, plan.writes, plan.conflicts}
      final_paths = plan.final_paths(current)
      raise Error.new("Git sequencer divergent file/directory conflict unsupported") if Checkout.path_collision(final_paths)
      Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
        max_entries: max_entries)
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_entries * 3, check: check)
      blocking_removals, trailing_removals = plan.partition_removals
      transition_dirs = Checkout.transition_directories(ours.keys, final_paths)
      plan.validate_symlinks!
      state = Sequencer::State.new(kind, branch, old_oid, target, parent,
        operation_author, text, allow_empty)
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
          raise Error.new("Git sequencer HEAD changed") unless head_ref_and_oid == {branch, old_oid}
          raise Error.new("Git sequencer index changed") unless @index.snapshot_checksum(max_index_bytes) == snapshot
          raise Error.new("Git sequencer state changed") if started && sequencer_state? != state
        end
        guard.call
        Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
        Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
          max_entries: max_entries)
        started = true
        sequencer_write_metadata!(admin, state)
        guard.call
        if planned = image
          raise Error.new("Git sequencer index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          lock.write(planned.data.to_slice)
          lock.flush
          lock.fsync
        end
        blocking_removals.each do |path, previous|
          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
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
        trailing_removals.each do |path, previous|
          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
          changed_paths << path
        end
        if image
          guard.call
          raise Error.new("Git sequencer admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
      rescue ex
        raise Sequencer::PartialPublication.new(changed_paths.dup, index_published, ex) if started
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
      if commit_result
        if conflicts.empty?
          begin
            committed = sequencer_continue(committer: committer,
              max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
          rescue ex : Sequencer::PartialCommit | Sequencer::EmptyResult
            raise ex
          rescue ex
            raise Sequencer::PartialPublication.new(changed_paths.dup, index_published, ex)
          end
        end
      else
        transient = DescriptorPath::Directory.open(@git_dir)
        begin
          begin
            sequencer_clear_metadata!(transient, state)
          rescue ex
            raise Sequencer::PartialPublication.new(changed_paths.dup, index_published, ex)
          end
        ensure
          transient.close
        end
      end
      Sequencer::Result.new(kind, old_oid, target, parent, changed_paths, conflicts, committed)
    end
  end
end
