module Git
  class Repository
    # Commit a resolved cherry-pick/revert after every conflict path has been
    # reduced to stage zero. The author/message captured at operation start is
    # reused unless the caller supplies an explicit message override.
    def sequencer_continue(*, committer : Signature, message : String? = nil,
                           max_object_bytes : Int32 = 8_388_608,
                           max_index_bytes : Int32 = 8_388_608,
                           check : Proc(Nil)? = nil) : String
      require_worktree!
      state = sequencer_state? || raise Error.new("no Git sequencer operation in progress")
      raise Error.new("Git sequencer HEAD changed since start") unless head == {state.branch, state.original_head}
      snapshot = @index.snapshot_checksum(max_index_bytes)
      raise Error.new("Git sequencer has unresolved paths") if @index.entries(max_index_bytes) { check.try &.call }.any? { |entry| entry.stage != 0 }
      text = message || state.message
      validate_sequencer_message!(text)
      tree = write_index_tree(max_index_bytes: max_index_bytes,
        max_tree_bytes: max_object_bytes, check: check)
      original_tree = commit(state.original_head, max_object_bytes) { check.try &.call }.tree
      raise Sequencer::EmptyResult.new if !state.allow_empty && tree == original_tree
      oid = write_commit(tree: tree, parents: [state.original_head], author: state.author,
        committer: committer, message: text, max_bytes: max_object_bytes, check: check)
      checked = -> do
        check.try &.call
        raise Error.new("Git sequencer changed during commit") unless head == {state.branch, state.original_head} &&
                                                                      sequencer_state? == state &&
                                                                      @index.snapshot_checksum(max_index_bytes) == snapshot
      end
      checked.call
      begin
        update_ref(state.branch, oid, expected_oid: state.original_head,
          log: References::LogEntry.new(committer, "#{Sequencer.label(state.kind)}: #{text.lines.first? || ""}"),
          max_object_bytes: max_object_bytes, check: checked)
      rescue ex
        raise Sequencer::PartialCommit.new(oid, ex) if head == {state.branch, oid}
        raise ex
      end
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        begin
          sequencer_clear_metadata!(admin, state)
        rescue ex
          raise Sequencer::PartialCommit.new(oid, ex)
        end
      ensure
        admin.close
      end
      oid
    end

    def cherry_pick_continue(*, committer : Signature, message : String? = nil,
                             max_object_bytes : Int32 = 8_388_608,
                             max_index_bytes : Int32 = 8_388_608,
                             check : Proc(Nil)? = nil) : String
      state = sequencer_state? || raise Error.new("no Git cherry-pick in progress")
      raise Error.new("Git sequencer operation is not a cherry-pick") unless state.kind.cherry_pick?
      sequencer_continue(committer: committer, message: message,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
    end

    def revert_continue(*, committer : Signature, message : String? = nil,
                        max_object_bytes : Int32 = 8_388_608,
                        max_index_bytes : Int32 = 8_388_608,
                        check : Proc(Nil)? = nil) : String
      state = sequencer_state? || raise Error.new("no Git revert in progress")
      raise Error.new("Git sequencer operation is not a revert") unless state.kind.revert?
      sequencer_continue(committer: committer, message: message,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
    end
  end
end
