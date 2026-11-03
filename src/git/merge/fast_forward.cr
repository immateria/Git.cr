module Git
  struct Merge
    record FastForwardResult, previous_oid : String, target_oid : String, changed_paths : Array(String)
  end

  class Repository
    # Advance a symbolic branch to a descendant commit only if the entire
    # tracked worktree is clean and the index exactly matches HEAD. Unlike a
    # destructive hard reset, this refuses staged or unstaged edits. It uses
    # the same bounded write/lock paths as the hard-reset implementation and
    # inherits its partial-publication error, filesystem and format limits.
    # This is fast-forward only: no merge commit or conflict handling.
    def fast_forward(source : String, *,
                     max_history_nodes : Int32 = 16_384,
                     max_object_bytes : Int32 = 8_388_608,
                     max_index_bytes : Int32 = 8_388_608,
                     max_total_bytes : Int64 = 67_108_864,
                     max_entries : Int32 = 10_000,
                     log : References::LogEntry? = nil,
                     check : Proc(Nil)? = nil) : Merge::FastForwardResult
      check!
      raise Error.new("Git fast-forward refuses in-progress merge") if merge_state?
      raise Error.new("Git fast-forward refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git fast-forward refuses in-progress rebase") if rebase_state?
      reference, old = head_ref_and_oid
      raise Error.new("Git fast-forward requires an existing symbolic branch HEAD") unless reference &&
                                                                                           reference.starts_with?("refs/heads/") && old
      target = History.resolve_commit(self, source, max_object_bytes, check)
      bases = merge_bases(old, target, max_nodes: max_history_nodes,
        max_commit_bytes: max_object_bytes, check: check)
      raise Error.new("Git merge is not a fast-forward") unless bases == [old]
      result = reset_head_hard(source, log: log, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, clean_only: true, check: check)
      Merge::FastForwardResult.new(old, target, result.changed_worktree_paths)
    end
  end
end
