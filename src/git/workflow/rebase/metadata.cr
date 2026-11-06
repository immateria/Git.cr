module Git
  class Repository
    private def rebase_write_initial_state!(state : Rebase::State) : Nil
      parent = DescriptorPath::Directory.open(@git_dir)
      child = nil.as(DescriptorPath::Directory?)
      created = false
      begin
        raise Error.new("Git rebase state already exists") if parent.stat?("rebase-merge")
        parent.mkdir_new("rebase-merge", 0o700)
        parent.sync
        created = true
        child = parent.open_directory("rebase-merge")
        files = {
          "head-name"       => "#{state.branch || "detached HEAD"}\n",
          "orig-head"       => "#{state.original_head}\n",
          "upstream"        => "#{state.upstream}\n",
          "onto"            => "#{state.onto}\n",
          "git-rebase-todo" => state.todo.empty? ? "" : state.todo.join("\n") + "\n",
          "state"           => rebase_dynamic_text(state),
        }
        files.each do |name, text|
          io = child.open_file(name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
          begin
            io.write(text.to_slice)
            io.flush
            io.fsync
          ensure
            io.close unless io.closed?
          end
          child.sync
        end
      rescue ex
        if created
          if child
            {"head-name", "orig-head", "upstream", "onto", "git-rebase-todo", "state", "state.lock"}.each do |name|
              child.unlink(name) if child.stat?(name)
            end
            child.sync
          end
          parent.rmdir("rebase-merge") if parent.stat?("rebase-merge")
          parent.sync
        end
        raise ex
      ensure
        child.try &.close
        parent.close
      end
    end

    private def rebase_clear_state!(state : Rebase::State) : Nil
      raise Error.new("Git rebase state changed during cleanup") unless rebase_state? == state
      raise Error.new("Git rebase replay still active during cleanup") if sequencer_state?
      parent = DescriptorPath::Directory.open(@git_dir)
      child = nil.as(DescriptorPath::Directory?)
      begin
        child = parent.open_directory("rebase-merge")
        {"head-name", "orig-head", "upstream", "onto", "git-rebase-todo", "state"}.each do |name|
          raise Error.new("Git rebase metadata missing during cleanup") unless child.stat?(name)
          child.unlink(name)
          child.sync
        end
        raise Error.new("Git rebase progress lock remains during cleanup") if child.stat?("state.lock")
        {"worktree-restore", "worktree-restore.required"}.each do |name|
          if child.stat?(name)
            child.unlink(name)
            child.sync
          end
        end
        child.close
        child = nil
        parent.rmdir("rebase-merge")
        parent.sync
      ensure
        child.try &.close
        parent.close
      end
    end

    private def rebase_read_file!(directory : DescriptorPath::Directory,
                                  name : String, max_bytes : Int32) : String
      io = directory.open_file(name, LibC::O_RDONLY | LibC::O_NONBLOCK)
      begin
        raise Error.new("Git rebase metadata is not regular") unless io.info.type.file?
        raise Error.new("Git rebase metadata budget exceeded") if io.info.size > max_bytes
        memory = IO::Memory.new
        IO.copy(io, memory, max_bytes.to_i64 + 1)
        raise Error.new("Git rebase metadata budget exceeded") if memory.size > max_bytes
        memory.to_s
      ensure
        io.close unless io.closed?
      end
    end

    private def rebase_dynamic_text(state : Rebase::State) : String
      "next #{state.next_index}\nexpected #{state.expected_head}\nkeep-empty #{state.keep_empty ? 1 : 0}\n"
    end

    private def rebase_mark_restoring!(directory : DescriptorPath::Directory, state : Rebase::State) : Nil
      raise Error.new("Git rebase state changed") unless rebase_state? == state
      replay_require_recovery!(directory, "worktree-restore")
      before = rebase_read_file!(directory, "state", 4_096)
      plain = rebase_dynamic_text(state)
      after = plain + "#{Sequencer::RESTORING}\n"
      raise Error.new("Git rebase dynamic state changed") unless before == plain || before == after
      replay_replace_metadata!(directory, "state", before, after)
    end
  end
end
