module Git
  struct Merge
    # :nodoc:
    def self.encode_relocations(paths : Array(String)) : String
      paths.each { |path| PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH) }
      raw = paths.join('\0')
      raise Error.new("Git conflict relocation metadata budget exceeded") if raw.bytesize > 65_536
      raw
    end

    # :nodoc:
    def self.decode_relocations(raw : String?) : Array(String)
      return [] of String if raw.nil? || raw.empty?
      paths = raw.split('\0')
      encode_relocations(paths)
      raise Error.new("Git conflict relocation metadata duplicates") unless paths.uniq.size == paths.size
      paths
    end

    # Turn an otherwise invalid file/directory index into ort's relocated
    # file conflict. The directory keeps its name; the file's stages and
    # worktree content move together. Never overwrite a pre-existing path.
    protected def self.relocate_directories(repository : Repository, plan : FilePlan,
                                            current : Array(Index::Entry),
                                            ours : Hash(String, Checkout::FileState),
                                            theirs : Hash(String, Checkout::FileState), *,
                                            their_label : String, max_object_bytes : Int32,
                                            max_total_bytes : Int64, max_entries : Int32,
                                            check : Proc(Nil)?) : FilePlan
      edits = plan.edits.dup
      writes = plan.writes.dup
      removals = plan.removals.dup
      conflicts = plan.conflicts.dup
      relocations = (plan.relocations + edits.map(&.path).reject { |path| ours.has_key?(path) || theirs.has_key?(path) }).uniq
      paths = plan.final_paths(current)
      reserved = (current.map(&.path) + ours.keys + theirs.keys + edits.map(&.path)).to_set
      while collision = Checkout.path_collision(paths)
        check.try &.call
        path = collision[0]
        edit = edits.find { |item| item.path == path }
        stages = if edit.is_a?(Index::PutStages)
                   edit.stages
                 else
                   state = if edit.is_a?(Index::Put)
                             Checkout::FileState.new(edit.mode, edit.oid)
                           else
                             ours[path]? || theirs[path]? || raise Error.new("Git directory conflict file missing")
                           end
                   stage = ours.has_key?(path) ? 2 : 3
                   [Index::Entry.new(path, state.mode, state.oid, stage, false, false)]
                 end
        label = ours.has_key?(path) ? "HEAD" : their_label
        stem = "#{path}~#{label.gsub('/', '_')}"
        relocated = stem
        suffix = 0
        loop do
          PathBytes.validate_relative!(relocated, max_depth: Metadata::MAX_DEPTH)
          break unless reserved.any? { |name| name == relocated || name.starts_with?(relocated + "/") || relocated.starts_with?(name + "/") }
          raise Error.new("Git conflict relocation name budget exceeded") if suffix >= max_entries
          relocated = "#{stem}_#{suffix}"
          suffix += 1
        end
        edits.reject! { |item| item.path == path }
        edits << Index::Remove.new(path) if current.any? { |entry| entry.path == path }
        edits << Index::PutStages.new(relocated, stages.map do |entry|
          Index::Entry.new(relocated, entry.mode, entry.oid, entry.stage, false, false)
        end)
        original_write = writes.find { |item| item.path == path }
        writes.reject! { |item| item.path == path }
        if original_write
          writes << Checkout::Write.new(relocated, original_write.mode, original_write.oid, original_write.data)
        else
          state = ours[path]? || theirs[path]? || raise Error.new("Git directory conflict content missing")
          kind, data = repository.object(state.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git directory conflict expected blob") unless kind == "blob"
          writes << Checkout::Write.new(relocated, state.mode, state.oid, data)
        end
        if previous = ours[path]?
          removals << {path, previous} unless removals.any? { |name, _| name == path }
        end
        conflicts.delete(path)
        conflicts << relocated
        relocations << relocated
        paths.delete(path)
        paths.add(relocated)
        reserved.add(relocated)
        raise Error.new("Git merge relocation entry budget exceeded") if paths.size > max_entries
        raise Error.new("Git merge total byte budget exceeded") if writes.sum(0_i64) { |write| write.data.bytesize.to_i64 } > max_total_bytes
      end
      encode_relocations(relocations) # Preflight the metadata before publication.
      FilePlan.new(edits, writes, removals, conflicts.sort, relocations)
    end
  end
end
