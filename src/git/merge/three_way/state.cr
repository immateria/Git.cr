module Git
  class Repository
    # Read a strictly bounded in-progress Git MERGE_HEAD, if present. The
    # companion state records the original ref and commit for fail-closed
    # continuation/abort after somebody switches branches externally.
    def merge_state? : {String, String, String}?
      check!
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        merge = merge_read_metadata?(admin, "MERGE_HEAD")
        return nil unless merge
        target = merge.strip
        ObjectId.valid!(target, @object_format)
        original = merge_read_metadata?(admin, "CRYSTAL_MERGE_ORIG") || raise Error.new("Git merge original state missing")
        lines = original.lines.map(&.strip)
        raise Error.new("Git merge original state invalid") unless lines.size == 2 &&
                                                                   lines[0].starts_with?("refs/heads/") &&
                                                                   RefName.valid?(lines[0])
        ObjectId.valid!(lines[1], @object_format)
        {lines[0], lines[1], target}
      ensure
        admin.close
      end
    end

    # Expose unmerged stages without requiring the system Git executable.
    # A missing side is nil, not a synthesized zero OID or a stage-zero file.
    def merge_conflicts(*, max_index_bytes : Int32 = 8_388_608,
                        check : Proc(Nil)? = nil) : Array(Merge::Conflict)
      raise Error.new("no Git merge in progress") unless merge_state?
      staged = @index.entries(max_index_bytes) { check.try &.call }
      Merge.conflicts_from_entries(staged)
    end
  end
end
