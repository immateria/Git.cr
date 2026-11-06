module Git
  class Repository
    protected def rebase_continue(*, committer : Signature, config : Config? = nil,
                                  max_object_bytes : Int32 = 8_388_608,
                                  max_index_bytes : Int32 = 8_388_608,
                                  max_total_bytes : Int64 = 67_108_864,
                                  max_entries : Int32 = 10_000,
                                  check : Proc(Nil)? = nil) : Rebase::Result
      config ||= self.config
      state = rebase_state? || raise Error.new("no Git rebase in progress")
      item = sequencer_state? || raise Error.new("Git rebase has no stopped replay to continue")
      rebase_validate_item!(state, item)
      source = state.todo[state.next_index]
      new_head = sequencer_continue(committer: committer,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
      begin
        state = rebase_advance_state!(state, state.next_index + 1, new_head)
      rescue ex
        raise Rebase::PartialProgress.new(source, new_head, ex)
      end
      rebase_run(state, config: config, committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    protected def rebase_skip(*, committer : Signature, config : Config? = nil,
                              max_object_bytes : Int32 = 8_388_608,
                              max_index_bytes : Int32 = 8_388_608,
                              max_total_bytes : Int64 = 67_108_864,
                              max_entries : Int32 = 10_000,
                              check : Proc(Nil)? = nil) : Rebase::Result
      config ||= self.config
      state = rebase_state? || raise Error.new("no Git rebase in progress")
      item = sequencer_state? || raise Error.new("Git rebase has no stopped replay to skip")
      rebase_validate_item!(state, item)
      sequencer_abort(config: config, max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
      state = rebase_advance_state!(state, state.next_index + 1, state.expected_head)
      rebase_run(state, config: config, committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    # Abort the entire rebase, not merely the currently stopped replay. If an
    # item is conflicted, its single-item state is first restored to the last
    # successfully replayed HEAD; then the branch/index/worktree are restored
    # to the original pre-rebase commit.
    protected def rebase_abort(*, committer : Signature, config : Config? = nil,
                               max_object_bytes : Int32 = 8_388_608,
                               max_index_bytes : Int32 = 8_388_608,
                               max_total_bytes : Int64 = 67_108_864,
                               max_entries : Int32 = 10_000,
                               check : Proc(Nil)? = nil) : Array(String)
      config ||= self.config
      state = rebase_state? || raise Error.new("no Git rebase in progress")
      changed = [] of String
      if item = sequencer_state?
        rebase_validate_item!(state, item)
        changed.concat(sequencer_abort(config: config, max_object_bytes: max_object_bytes,
          max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
          max_entries: max_entries, check: check))
      end
      branch, current = head_ref_and_oid
      raise Error.new("Git rebase abort branch changed") unless branch == state.branch && current
      raise Error.new("Git rebase abort HEAD changed") unless {state.expected_head, state.original_head}.includes?(current)
      # HEAD may already be restored while the index still describes the
      # replayed tree. Reconcile all three components before clearing state.
      changed.concat(rebase_move_branch!(state, state.expected_head, state.original_head, config: config,
        log: References::LogEntry.new(committer, "rebase (abort): returning to #{state.branch || state.original_head}"),
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check, restore: true))
      refreshed = rebase_state? || raise Error.new("Git rebase state disappeared during abort")
      rebase_clear_state!(refreshed)
      changed.uniq
    end
  end
end
