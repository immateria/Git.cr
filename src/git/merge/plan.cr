require "set"

module Git
  struct Merge
    # Shared publication plan for three-way merges and sequencer replay.
    # Blob merging may materialize objects in the repository, but branch refs,
    # operation metadata, index and worktree publication remain with the
    # respective Repository entry points.
    record FilePlan,
      edits : Array(Index::Edit),
      writes : Array(Checkout::Write),
      removals : Array({String, Checkout::FileState}),
      conflicts : Array(String) do
      def final_paths(current : Array(Index::Entry)) : Set(String)
        result = current.map(&.path).to_set
        edits.each do |edit|
          case edit
          when Index::Remove
            result.delete(edit.path)
          else
            result.add(edit.path)
          end
        end
        result
      end

      def partition_removals : {Array({String, Checkout::FileState}), Array({String, Checkout::FileState})}
        write_paths = writes.map(&.path)
        removals.partition do |path, _state|
          write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
        end
      end

      # Validate before any operation metadata or worktree mutation is written.
      def validate_symlinks! : Nil
        writes.each do |write|
          if write.mode == "120000"
            raise Error.new("invalid Git symlink target") if write.data.empty? || write.data.includes?('\0') || write.data.bytesize > 4095
          end
        end
      end
    end

    # Both merge and sequencer require the index to name exactly HEAD, including
    # index flags. Treat this as one shared invariant, not operation policy.
    def self.index_matches_head?(current : Array(Index::Entry), ours : Hash(String, Checkout::FileState)) : Bool
      current.size == ours.size && current.all? do |entry|
        entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
          ours[entry.path]?.try { |state| state.mode == entry.mode && state.oid == entry.oid } == true
      end
    end

    # Convert unmerged Git index stages back into one conflict per path. Missing
    # stages must remain nil; they cannot be replaced with synthetic blobs.
    def self.conflicts_from_entries(staged : Array(Index::Entry)) : Array(Conflict)
      groups = {} of String => Array(Index::Entry)
      staged.each do |entry|
        (groups[entry.path] ||= [] of Index::Entry) << entry if entry.stage != 0
      end
      groups.keys.sort.map do |path|
        entries = groups[path]
        states = (1..3).map do |stage|
          entry = entries.find { |candidate| candidate.stage == stage }
          entry ? Checkout::FileState.new(entry.mode, entry.oid) : nil
        end
        Conflict.new(path, states[0], states[1], states[2])
      end
    end

    # Preserve each caller's error label and marker source while centralizing
    # the otherwise identical rename/conflict/blob-budget decisions. Object
    # writes by merge_blob are intentionally unchanged from the original plan.
    def self.plan_files(repository : Repository, names : Array(String),
                        base : Hash(String, Checkout::FileState),
                        ours : Hash(String, Checkout::FileState),
                        theirs : Hash(String, Checkout::FileState),
                        renames : RenamePlan, *, marker_label : String,
                        operation : String, max_object_bytes : Int32,
                        max_total_bytes : Int64, check : Proc(Nil)?) : FilePlan
      edits = [] of Index::Edit
      writes = [] of Checkout::Write
      removals = [] of {String, Checkout::FileState}
      conflicts = [] of String
      transferred = 0_i64
      names.each do |path|
        check.try &.call
        ancestor = base[path]?
        local = ours[path]?
        remote = theirs[path]?
        desired = if local == remote || remote == ancestor
                    local
                  elsif local == ancestor
                    remote
                  else
                    nil
                  end
        divergent = local != remote && local != ancestor && remote != ancestor
        if override = renames.conflicts[path]?
          ancestor, local, remote = {override.base, override.ours, override.theirs}
          divergent = true
        elsif renames.resolutions.has_key?(path)
          desired = renames.resolutions[path]
          divergent = false
        end
        if resolved = divergent ? merge_blob(repository, ancestor, local, remote, max_object_bytes, check) : nil
          desired = resolved[0]
          divergent = false
        end
        if divergent
          conflicts << path
          edits << conflict(path, ancestor, local, remote)
          # A marker is only a worktree aid: the index keeps real conflict stages.
          if marker = markers(repository, local, remote, marker_label, max_object_bytes, check)
            transferred += marker.bytesize
            raise Error.new("#{operation} total byte budget exceeded") if transferred > max_total_bytes
            writes << Checkout::Write.new(path, local.not_nil!.mode,
              ObjectId.digest("blob", marker, repository.object_format), marker)
          elsif local.nil? && remote
            object_kind, raw = repository.object(remote.oid, max_object_bytes) { check.try &.call }
            raise Error.new("#{operation} conflict target is not a blob") unless object_kind == "blob"
            transferred += raw.bytesize
            raise Error.new("#{operation} total byte budget exceeded") if transferred > max_total_bytes
            writes << Checkout::Write.new(path, remote.mode, remote.oid, raw)
          end
        elsif local != desired
          if next_state = desired
            edits << Index::Put.new(path, next_state.mode, next_state.oid)
            object_kind, raw = repository.object(next_state.oid, max_object_bytes) { check.try &.call }
            raise Error.new("#{operation} target is not a blob") unless object_kind == "blob"
            transferred += raw.bytesize
            raise Error.new("#{operation} total byte budget exceeded") if transferred > max_total_bytes
            writes << Checkout::Write.new(path, next_state.mode, next_state.oid, raw)
          elsif local_state = local
            edits << Index::Remove.new(path)
            removals << {path, local_state}
          end
        end
      end
      FilePlan.new(edits, writes, removals, conflicts)
    end
  end
end
