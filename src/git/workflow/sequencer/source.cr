module Git
  struct Sequencer
    protected def self.head_name(kind : Kind) : String
      case kind
      when .cherry_pick? then "CHERRY_PICK_HEAD"
      when .revert?      then "REVERT_HEAD"
      when .rebase?      then "REBASE_HEAD"
      else                    raise Error.new("unknown Git sequencer kind")
      end
    end

    protected def self.label(kind : Kind) : String
      case kind
      when .cherry_pick? then "cherry-pick"
      when .revert?      then "revert"
      when .rebase?      then "rebase"
      else                    raise Error.new("unknown Git sequencer kind")
      end
    end

    protected def self.read_source(repository : Repository, oid : String, max_bytes : Int32,
                                   check : Proc(Nil)?) : Source
      object_kind, raw = repository.object(oid, max_bytes) { check.try &.call }
      raise Error.new("Git sequencer source is not a commit") unless object_kind == "commit"
      separator = raw.byte_index("\n\n") || raise Error.new("Git sequencer commit missing header separator")
      headers = raw.byte_slice(0, separator)
      message = raw.byte_slice(separator + 2, raw.bytesize - separator - 2)
      tree = nil.as(String?)
      parents = [] of String
      author = nil.as(Signature?)
      headers.each_line do |line|
        case
        when line.starts_with?("tree ")
          tree = ObjectId.valid!(line.byte_slice(5).strip, repository.object_format)
        when line.starts_with?("parent ")
          raise Error.new("Git sequencer source has too many parents") if parents.size >= 16
          parents << ObjectId.valid!(line.byte_slice(7).strip, repository.object_format)
        when line.starts_with?("author ")
          author = Signature.parse_git_header(line.byte_slice(7).strip)
        end
      end
      raise Error.new("invalid Git sequencer commit header") unless tree && author
      Source.new(oid, tree.not_nil!, parents, author.not_nil!, message)
    end

    protected def self.selected_parent(source : Source, mainline : Int32?) : String?
      if source.parents.size <= 1
        raise Error.new("Git sequencer mainline requires a merge commit") if mainline
        return source.parents.first?
      end
      selected = mainline || raise Error.new("Git sequencer merge commit requires mainline parent")
      raise Error.new("invalid Git sequencer mainline parent") if selected < 1 || selected > source.parents.size
      source.parents[selected - 1]
    end

    protected def self.default_revert_message(source : Source) : String
      subject = source.message.lines.first? || ""
      "Revert \"#{subject}\"\n\nThis reverts commit #{source.oid}.\n"
    end
  end
end
