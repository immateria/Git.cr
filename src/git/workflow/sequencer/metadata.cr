module Git
  class Repository
    private def validate_sequencer_message!(message : String) : Nil
      raise Error.new("Git sequencer message invalid") if message.includes?('\0') || message.bytesize > 65_536
    end

    private def sequencer_metadata_exists? : Bool
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        {"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "MERGE_MSG", "CRYSTAL_SEQUENCER_ORIG",
         "CRYSTAL_SEQUENCER_PARENT", "CRYSTAL_SEQUENCER_AUTHOR",
         "CRYSTAL_SEQUENCER_ALLOW_EMPTY", "CRYSTAL_SEQUENCER_PATHS", "CRYSTAL_SEQUENCER_RESTORE",
         "CRYSTAL_SEQUENCER_RESTORE.lock", "CRYSTAL_SEQUENCER_RESTORE.required",
         "CRYSTAL_SEQUENCER_ORIG.lock"}.any? { |name| !!admin.stat?(name) }
      ensure
        admin.close
      end
    end

    private def sequencer_read_metadata?(admin : DescriptorPath::Directory, name : String) : String?
      io = admin.open_file?(name, LibC::O_RDONLY | LibC::O_NONBLOCK)
      return nil unless io
      begin
        raise Error.new("Git sequencer metadata not a regular file") unless io.info.type.file?
        raise Error.new("Git sequencer metadata budget exceeded") if io.info.size > 65_536
        contents = IO::Memory.new
        IO.copy(io, contents, 65_537_i64)
        raise Error.new("Git sequencer metadata budget exceeded") if contents.size > 65_536
        contents.to_s
      ensure
        io.close unless io.closed?
      end
    end

    private def sequencer_write_metadata!(admin : DescriptorPath::Directory,
                                          state : Sequencer::State, recovery_data : String = "") : Nil
      head_name = Sequencer.head_name(state.kind)
      contents = {
        "CRYSTAL_SEQUENCER_ORIG"        => "#{state.branch || "-"}\n#{state.original_head}\n#{Merge::Recovery::STATE_VERSION}\n",
        "CRYSTAL_SEQUENCER_PARENT"      => "#{state.parent || "-"}\n",
        "CRYSTAL_SEQUENCER_AUTHOR"      => "#{state.author.to_git_header}\n",
        "CRYSTAL_SEQUENCER_ALLOW_EMPTY" => state.allow_empty ? "1\n" : "0\n",
        "CRYSTAL_SEQUENCER_PATHS"       => recovery_data,
        "MERGE_MSG"                     => state.message,
        head_name                       => "#{state.source}\n",
      }
      contents.each do |name, value|
        io = admin.open_file(name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        begin
          io.write(value.to_slice)
          io.flush
          io.fsync
        ensure
          io.close unless io.closed?
        end
        admin.sync
      end
    end

    private def sequencer_clear_metadata!(admin : DescriptorPath::Directory,
                                          state : Sequencer::State) : Nil
      raise Error.new("Git sequencer admin directory redirected") unless admin.attached_at?(@git_dir)
      raise Error.new("Git sequencer state changed") unless sequencer_state? == state
      {"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "MERGE_MSG", "CRYSTAL_SEQUENCER_ORIG",
       "CRYSTAL_SEQUENCER_PARENT", "CRYSTAL_SEQUENCER_AUTHOR",
       "CRYSTAL_SEQUENCER_ALLOW_EMPTY"}.each do |name|
        if name == Sequencer.head_name(state.kind) || !{"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"}.includes?(name)
          raise Error.new("Git sequencer metadata missing during cleanup") unless admin.stat?(name)
          admin.unlink(name)
          admin.sync
        else
          raise Error.new("unexpected Git sequencer head file") if admin.stat?(name)
        end
      end
      if admin.stat?("CRYSTAL_SEQUENCER_PATHS")
        admin.unlink("CRYSTAL_SEQUENCER_PATHS")
        admin.sync
      end
      {"CRYSTAL_SEQUENCER_RESTORE", "CRYSTAL_SEQUENCER_RESTORE.required"}.each do |name|
        if admin.stat?(name)
          admin.unlink(name)
          admin.sync
        end
      end
    end

    private def sequencer_mark_restoring!(admin : DescriptorPath::Directory, state : Sequencer::State) : Nil
      raise Error.new("Git sequencer state changed") unless sequencer_state? == state
      replay_require_recovery!(admin, "CRYSTAL_SEQUENCER_RESTORE")
      before = sequencer_read_metadata?(admin, "CRYSTAL_SEQUENCER_ORIG") ||
               raise Error.new("Git sequencer original state missing")
      lines = before.lines.map(&.strip)
      return if lines.size == 4 && lines[3] == Sequencer::RESTORING
      version = lines.size == 3 ? lines[2] : "legacy"
      after = (lines.first(2) + [version, Sequencer::RESTORING]).join('\n') + "\n"
      replay_replace_metadata!(admin, "CRYSTAL_SEQUENCER_ORIG", before, after)
    end
  end
end
