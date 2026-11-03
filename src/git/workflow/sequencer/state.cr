module Git
  class Repository
    # Return the durable single-item sequencer state. Companion metadata binds
    # the operation to its original branch/HEAD and selected source parent so
    # continue/abort fail closed after external repository mutation.
    protected def sequencer_state? : Sequencer::State?
      check!
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        cherry = sequencer_read_metadata?(admin, "CHERRY_PICK_HEAD")
        revert = sequencer_read_metadata?(admin, "REVERT_HEAD")
        rebase = sequencer_read_metadata?(admin, "REBASE_HEAD")
        count = (cherry ? 1 : 0) + (revert ? 1 : 0) + (rebase ? 1 : 0)
        raise Error.new("conflicting Git sequencer head files") if count > 1
        head_value = cherry || revert || rebase
        return nil unless head_value
        kind = if cherry
                 Sequencer::Kind::CherryPick
               elsif revert
                 Sequencer::Kind::Revert
               else
                 Sequencer::Kind::Rebase
               end
        source = ObjectId.valid!(head_value.strip, @object_format)
        original = sequencer_read_metadata?(admin, "CRYSTAL_SEQUENCER_ORIG") ||
                   raise Error.new("Git sequencer original state missing")
        lines = original.lines.map(&.strip)
        raise Error.new("Git sequencer original state invalid") unless lines.size == 2 &&
                                                                       lines[0].starts_with?("refs/heads/") &&
                                                                       RefName.valid?(lines[0])
        original_head = ObjectId.valid!(lines[1], @object_format)
        parent_text = sequencer_read_metadata?(admin, "CRYSTAL_SEQUENCER_PARENT") ||
                      raise Error.new("Git sequencer parent state missing")
        parent_raw = parent_text.strip
        parent = parent_raw == "-" ? nil : ObjectId.valid!(parent_raw, @object_format)
        author_text = sequencer_read_metadata?(admin, "CRYSTAL_SEQUENCER_AUTHOR") ||
                      raise Error.new("Git sequencer author state missing")
        author = Signature.parse_git_header(author_text.strip)
        message = sequencer_read_metadata?(admin, "MERGE_MSG") ||
                  raise Error.new("Git sequencer message missing")
        empty_text = sequencer_read_metadata?(admin, "CRYSTAL_SEQUENCER_ALLOW_EMPTY") ||
                     raise Error.new("Git sequencer empty-state missing")
        allow_empty = case empty_text.strip
                      when "0" then false
                      when "1" then true
                      else          raise Error.new("Git sequencer empty-state invalid")
                      end
        Sequencer::State.new(kind, lines[0], original_head, source, parent,
          author, message, allow_empty)
      ensure
        admin.close
      end
    end

    protected def sequencer_conflicts(*, max_index_bytes : Int32 = 8_388_608,
                                      check : Proc(Nil)? = nil) : Array(Merge::Conflict)
      raise Error.new("no Git sequencer operation in progress") unless sequencer_state?
      staged = @index.entries(max_index_bytes) { check.try &.call }
      Merge.conflicts_from_entries(staged)
    end
  end
end
