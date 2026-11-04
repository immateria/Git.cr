module Git
  struct Merge
    record FastForwardResult, previous_oid : String, target_oid : String, changed_paths : Array(String)
  end

  class Repository
    # `git merge --ff-only <source>`: advance the current branch (or detached
    # HEAD) to a descendant commit, only if the tracked worktree is clean and
    # the index matches HEAD (unlike a hard reset, staged or unstaged edits are
    # refused). ORIG_HEAD records the previous commit. With actor, the branch
    # (when attached) and HEAD reflogs get Git's "merge <source>: Fast-forward".
    # It shares the hard reset's write path, partial-publication error and
    # filesystem limits. No merge commit or conflict handling.
    def fast_forward(source : String, *,
                     max_history_nodes : Int32 = 16_384,
                     max_object_bytes : Int32 = 8_388_608,
                     max_index_bytes : Int32 = 8_388_608,
                     max_total_bytes : Int64 = 67_108_864,
                     max_entries : Int32 = 10_000,
                     actor : Signature? = nil,
                     check : Proc(Nil)? = nil) : Merge::FastForwardResult
      fast_forward_as("merge #{source}", source, max_history_nodes: max_history_nodes,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, actor: actor, check: check)
    end

    # fast_forward, logging as Git's reflog action (`merge <source>`, `pull`).
    protected def fast_forward_as(action : String, source : String, *,
                                  max_history_nodes : Int32 = 16_384,
                                  max_object_bytes : Int32 = 8_388_608,
                                  max_index_bytes : Int32 = 8_388_608,
                                  max_total_bytes : Int64 = 67_108_864,
                                  max_entries : Int32 = 10_000,
                                  actor : Signature? = nil,
                                  check : Proc(Nil)? = nil) : Merge::FastForwardResult
      check!
      raise Error.new("Git fast-forward refuses in-progress merge") if merge_state?
      raise Error.new("Git fast-forward refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git fast-forward refuses in-progress rebase") if rebase_state?
      reference, old = head_ref_and_oid
      unless old && (reference.nil? || reference.starts_with?("refs/heads/"))
        raise Error.new("Git fast-forward requires an existing branch or detached HEAD")
      end
      target = History.resolve_commit(self, source, max_object_bytes, check)
      bases = merge_bases(old, target, max_nodes: max_history_nodes,
        max_commit_bytes: max_object_bytes, check: check)
      raise Error.new("Git merge is not a fast-forward") unless bases == [old]
      log = actor.try { |who| References::LogEntry.new(who, "#{action}: Fast-forward") }
      result = reset_head_hard(source, log: log, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, clean_only: true, check: check)
      Merge::FastForwardResult.new(old, target, result.changed_worktree_paths)
    end
  end
end
