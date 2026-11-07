module Git
  class Repository
    private def rebase_run(initial : Rebase::State, *, committer : Signature,
                           max_object_bytes : Int32, max_index_bytes : Int32,
                           max_total_bytes : Int64, max_entries : Int32,
                           check : Proc(Nil)?, config : Config) : Rebase::Result
      state = initial
      loop do
        branch, current = head_ref_and_oid
        raise Error.new("Git rebase branch changed") unless branch == state.branch && current == state.expected_head
        raise Error.new("Git rebase progress changed") unless rebase_state? == state
        if state.next_index >= state.todo.size
          raise Error.new("Git rebase sequencer state remains at completion") if sequencer_state?
          final_head = state.expected_head
          rebase_clear_state!(state)
          return Rebase::Result.new(state.branch, state.original_head, state.onto,
            final_head, state.todo.size, state.todo.size, [] of String, true)
        end
        raise Error.new("Git rebase unexpected stopped sequencer") if sequencer_state?
        source = state.todo[state.next_index]
        # Git keeps commits whose own tree was already empty relative to their
        # parent; keep_empty only controls replays that become empty on `onto`.
        item = Sequencer.read_source(self, source, max_object_bytes, check)
        originally_empty = if parent = item.parents.first?
                             item.tree == read_commit(parent, max_bytes: max_object_bytes, check: check).tree
                           else
                             false
                           end
        result = begin
          sequencer_start(Sequencer::Kind::Rebase, source, committer: committer,
            author: nil, message: nil, mainline: nil, allow_empty: state.keep_empty || originally_empty, config: config,
            max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
            max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
        rescue ex : Sequencer::EmptyCommit
          # Default non-interactive rebase drops a replay that has become empty.
          # The single-item state remains durable until it is explicitly
          # restored, so skip uses the same recovery path as a user request.
          raise ex if state.keep_empty
          item = sequencer_state? || raise Error.new("Git rebase empty replay state missing")
          rebase_validate_item!(state, item)
          sequencer_abort(config: config, max_object_bytes: max_object_bytes,
            max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
            max_entries: max_entries, check: check)
          state = rebase_advance_state!(state, state.next_index + 1, state.expected_head)
          next
        end
        unless result.conflicts.empty?
          return Rebase::Result.new(state.branch, state.original_head, state.onto,
            state.expected_head, state.next_index, state.todo.size,
            result.conflicts, false)
        end
        new_head = result.commit_oid || raise Error.new("Git rebase clean replay did not commit")
        begin
          state = rebase_advance_state!(state, state.next_index + 1, new_head)
        rescue ex
          raise Rebase::PartialProgress.new(source, new_head, ex)
        end
      end
    end
  end
end
