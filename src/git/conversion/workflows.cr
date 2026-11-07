module Git
  class Conversion
    # Project the final index and canonical plan into checkout's index-first
    # attribute source. Explicitly absent attributes suppress worktree fallback.
    def self.for_index(repository : Repository, current : Array(Index::Entry), *,
                       edits : Array(Index::Edit) = [] of Index::Edit,
                       writes : Array(Checkout::Write) = [] of Checkout::Write,
                       config : Config? = nil, max_bytes : Int32 = 8_388_608,
                       max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Conversion
      raise ArgumentError.new("invalid Git conversion byte budget") if max_bytes < 1
      raise ArgumentError.new("invalid Git conversion index byte budget") if max_index_bytes < 128
      check.try &.call
      blobs = {} of String => String?
      stages = {} of String => Int32
      current.each do |entry|
        check.try &.call
        next unless File.basename(entry.path) == ".gitattributes"
        PathBytes.validate_relative!(entry.path, max_depth: Metadata::MAX_DEPTH)
        blobs[entry.path] = nil unless blobs.has_key?(entry.path)
        next unless entry.stage == 0 || entry.stage == 2
        next if stages[entry.path]? == 0
        stages[entry.path] = entry.stage
        blobs[entry.path] = {"100644", "100755"}.includes?(entry.mode) ? entry.oid : nil
      end
      edits.each do |edit|
        check.try &.call
        next unless File.basename(edit.path) == ".gitattributes"
        PathBytes.validate_relative!(edit.path, max_depth: Metadata::MAX_DEPTH)
        case edit
        when Index::Put
          blobs[edit.path] = {"100644", "100755"}.includes?(edit.mode) ? edit.oid : nil
        when Index::Remove
          blobs[edit.path] = nil
        when Index::PutStages
          selected = edit.stages.find { |entry| entry.stage == 0 } || edit.stages.find { |entry| entry.stage == 2 }
          blobs[edit.path] = selected && {"100644", "100755"}.includes?(selected.mode) ? selected.oid : nil
        end
      end
      bytes = 0_i64
      writes.each do |write|
        check.try &.call
        next unless File.basename(write.path) == ".gitattributes"
        PathBytes.validate_relative!(write.path, max_depth: Metadata::MAX_DEPTH)
        if {"100644", "100755"}.includes?(write.mode)
          # Marker bytes need not match write.oid or exist in the object DB.
          bytes += write.data.bytesize
          raise Error.new("Git conversion attribute byte budget exceeded") if bytes > max_bytes
          blobs[write.path] = repository.write_blob(write.data, max_bytes: max_bytes.to_i64, check: check)
        else
          blobs[write.path] = nil
        end
      end
      new(repository, config: config, attribute_blobs: blobs, worktree_fallback: true,
        max_bytes: max_bytes, max_index_bytes: max_index_bytes, check: check)
    end

    # Keep object/index identities canonical while preparing all output bytes
    # before any caller publishes worktree files or operation metadata.
    def materialize(writes : Array(Checkout::Write), *, max_total_bytes : Int64,
                    operation : String = "Git checkout") : Array(Checkout::Write)
      raise ArgumentError.new("invalid #{operation} total byte budget") if max_total_bytes < 0
      @check.try &.call
      total = 0_i64
      writes.map do |write|
        validate_workflow_file!(write.path, write.mode, write.oid)
        validate_size!(write.data.bytesize)
        data = write.mode == "120000" ? write.data : checkout(write.path, write.data)
        total += data.bytesize
        raise Error.new("#{operation} total byte budget exceeded") if total > max_total_bytes
        @check.try &.call
        Checkout::Write.new(write.path, write.mode, write.oid, data)
      end
    end

    # Immutable canonical states become exact raw identities for overwrite and
    # recovery guards. Read and expanded-output budgets are bounded separately.
    def raw_states(states : Hash(String, Checkout::FileState), *, max_total_bytes : Int64,
                   operation : String = "Git checkout") : Hash(String, Checkout::FileState)
      raise ArgumentError.new("invalid #{operation} total byte budget") if max_total_bytes < 0
      @check.try &.call
      reads = 0_i64
      outputs = 0_i64
      result = {} of String => Checkout::FileState
      states.each do |path, state|
        validate_workflow_file!(path, state.mode, state.oid)
        kind, bytes = @repository.object(state.oid, @max_bytes) { @check.try &.call }
        raise Error.new("#{operation} target not a blob") unless kind == "blob"
        reads += bytes.bytesize
        raise Error.new("#{operation} total read byte budget exceeded") if reads > max_total_bytes
        data = state.mode == "120000" ? bytes : checkout(path, bytes)
        outputs += data.bytesize
        raise Error.new("#{operation} total byte budget exceeded") if outputs > max_total_bytes
        @check.try &.call
        result[path] = Checkout::FileState.new(state.mode, ObjectId.digest("blob", data, @repository.object_format))
      end
      result
    end

    private def validate_workflow_file!(path : String, mode : String, oid : String) : Nil
      @check.try &.call
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      raise Error.new("unsupported Git conversion file mode") unless {"100644", "100755", "120000"}.includes?(mode)
      ObjectId.valid!(oid, @repository.object_format)
    end
  end
end
