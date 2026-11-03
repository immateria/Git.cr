module Git
  class Repository
    private def rebase_validate_item!(state : Rebase::State, item : Sequencer::State) : Nil
      raise Error.new("Git rebase stopped operation kind changed") unless item.kind.rebase?
      raise Error.new("Git rebase stopped item index invalid") if state.next_index >= state.todo.size
      raise Error.new("Git rebase stopped source changed") unless item.source == state.todo[state.next_index]
      raise Error.new("Git rebase stopped branch changed") unless item.branch == state.branch
      raise Error.new("Git rebase stopped HEAD changed") unless item.original_head == state.expected_head &&
                                                                head == {state.branch, state.expected_head}
    end

    private def rebase_advance_state!(state : Rebase::State, next_index : Int32,
                                      expected_head : String) : Rebase::State
      raise Error.new("Git rebase state changed before progress update") unless rebase_state? == state
      updated = Rebase::State.new(state.branch, state.original_head, state.upstream,
        state.onto, state.todo, next_index, expected_head, state.keep_empty)
      parent = DescriptorPath::Directory.open(@git_dir)
      child = nil.as(DescriptorPath::Directory?)
      lock = nil.as(IO::FileDescriptor?)
      begin
        child = parent.open_directory("rebase-merge")
        lock = child.open_file("state.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        text = rebase_dynamic_text(updated)
        lock.write(text.to_slice)
        lock.flush
        lock.fsync
        raise Error.new("Git rebase state changed during progress update") unless rebase_state? == state
        child.rename("state.lock", "state")
        child.sync
        updated
      ensure
        if io = lock
          if child && child.same_inode?("state.lock", io)
            child.unlink("state.lock")
            child.sync
          end
          io.close unless io.closed?
        end
        child.try &.close
        parent.close
      end
    end
  end
end
