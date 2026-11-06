module Git
  class Repository
    # Apply a stash's base->worktree delta to a clean current HEAD without
    # creating a commit. Conflicts use Git index stages 1/2/3 and worktree
    # markers but leave the stash entry intact and no sequencer metadata.
    # restore_index reproduces the saved index exactly and is intentionally
    # restricted to the original base commit in this first native slice.
    protected def stash_apply(position : Int32 = 0, *, actor : Signature,
                              restore_index : Bool = false,
                              max_object_bytes : Int32 = 8_388_608,
                              max_index_bytes : Int32 = 8_388_608,
                              max_total_bytes : Int64 = 67_108_864,
                              max_entries : Int32 = 10_000,
                              max_log_bytes : Int32 = 8_388_608,
                              check : Proc(Nil)? = nil) : Stash::Applied
      entry = stash_show(position, max_log_bytes: max_log_bytes,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
      untracked_writes, untracked_bytes = stash_untracked_writes(entry.untracked_oid,
        max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
      tracked_budget = max_total_bytes - untracked_bytes
      raise Error.new("Git stash total byte budget exceeded") if tracked_budget < max_object_bytes
      if restore_index
        current_head = head_ref_and_oid[1]
        raise Error.new("Git stash --index requires original base HEAD") unless current_head == entry.base_oid
      end
      expected_head = head_ref_and_oid
      result = nil.as(Sequencer::Result?)
      begin
        result = sequencer_start(Sequencer::Kind::CherryPick, entry.oid,
          committer: actor, author: nil, message: nil, mainline: 1,
          allow_empty: true, max_object_bytes: max_object_bytes,
          max_index_bytes: max_index_bytes, max_total_bytes: tracked_budget,
          max_entries: max_entries, check: check, commit_result: false)
      rescue ex : Sequencer::PartialPublication
        raise Stash::PartialApply.new(entry.oid, ex.changed_paths, [] of String,
          false, ex)
      end
      applied = result.not_nil!
      changed_paths = applied.changed_paths.dup
      restored = false
      if applied.conflicts.empty?
        begin
          if restore_index
            read_tree(entry.index_oid, max_object_bytes: max_object_bytes,
              max_index_bytes: max_index_bytes, max_entries: max_entries, check: check)
            restored = true
          else
            # `git stash apply` does not generally reinstate the saved index.
            # Existing paths are reset to the current HEAD's index state while
            # genuinely new paths produced by the stash remain staged, which
            # is how Git can represent an added tracked path without calling it
            # untracked. Conflicts retain their stage sets and skip this step.
            stash_normalize_apply_index!(max_object_bytes: max_object_bytes,
              max_index_bytes: max_index_bytes, max_entries: max_entries, check: check)
          end
        rescue ex
          raise Stash::PartialApply.new(entry.oid, changed_paths,
            applied.conflicts, restored, ex)
        end
      end
      unless untracked_writes.empty?
        guard = -> do
          check.try &.call
          raise Error.new("Git stash apply HEAD changed during untracked restore") unless head_ref_and_oid == expected_head
          raise Error.new("Git stash apply sequencer metadata reappeared") if sequencer_state?
        end
        begin
          guard.call
          untracked_writes.each do |write|
            Checkout.require_free_destination!(@root, write.path)
          end
          untracked_writes.each_with_index do |write, sequence|
            Checkout.write(@root, write, sequence, expected_old: nil,
              format: @object_format, check: guard)
            changed_paths << write.path
          end
        rescue ex
          raise Stash::PartialApply.new(entry.oid, changed_paths,
            applied.conflicts, restored, ex)
        end
      end
      Stash::Applied.new(entry, changed_paths, applied.conflicts, restored)
    end

    # Apply and remove only after a conflict-free application. A conflict is
    # a successful stopped state: the stash remains on the stack for recovery.
    protected def stash_pop(position : Int32 = 0, *, actor : Signature,
                            restore_index : Bool = false,
                            max_object_bytes : Int32 = 8_388_608,
                            max_index_bytes : Int32 = 8_388_608,
                            max_total_bytes : Int64 = 67_108_864,
                            max_entries : Int32 = 10_000,
                            max_log_bytes : Int32 = 8_388_608,
                            check : Proc(Nil)? = nil) : Stash::Popped
      applied = stash_apply(position, actor: actor, restore_index: restore_index,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries,
        max_log_bytes: max_log_bytes, check: check)
      return Stash::Popped.new(applied, false) unless applied.conflicts.empty?
      begin
        stash_drop(position, max_log_bytes: max_log_bytes,
          max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
      rescue ex
        raise Stash::PartialPop.new(applied, ex)
      end
      Stash::Popped.new(applied, true)
    end
  end
end
