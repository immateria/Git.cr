module Git
  module Reset
    enum Mode
      Soft
      Mixed
      Hard
    end

    record Result, reference : String, previous_oid : String, target_oid : String,
      mode : Mode, changed_index_paths : Array(String),
      changed_worktree_paths : Array(String) = [] of String

    # Ref and index are separate Git filesystem publications. Any late
    # failure after the ref rename means callers must re-inspect both; this
    # is not a global rollback or crash-atomic transaction.
    class PartialPublication < Git::Error
      getter reference_published : Bool
      getter index_published : Bool
      getter original_error : Exception
      getter changed_worktree_paths : Array(String)

      def initialize(@reference_published : Bool, @index_published : Bool, @original_error : Exception,
                     @changed_worktree_paths : Array(String) = [] of String)
        super("Git reset partially published (#{@original_error.class}); inspect HEAD, index and worktree")
      end
    end
  end

  class Repository
    # Move the current symbolic branch to a commit and optionally reset the
    # entire index to the target tree. Soft preserves index/worktree; Mixed
    # resets index but preserves worktree; Hard changes all three, explicitly
    # discarding tracked worktree changes. Detached HEAD, ORIG_HEAD/ref-log
    # automation and merge-in-progress state are not yet supported. No
    # subprocess, filter, hook, or implicit policy grant.
    def reset(source : String = "HEAD", *, mode : Reset::Mode = Reset::Mode::Mixed,
              log : References::LogEntry? = nil,
              max_object_bytes : Int32 = 8_388_608,
              max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864,
              max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Reset::Result
      if mode.hard?
        return reset_head_hard(source, log: log, max_object_bytes: max_object_bytes,
          max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
          max_entries: max_entries, check: check)
      end
      require_worktree!
      raise Error.new("Git reset refuses in-progress merge") if merge_state?
      raise Error.new("Git reset refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git reset refuses in-progress rebase") if rebase_state?
      raise ArgumentError.new("invalid Git reset budgets") if max_object_bytes < 128 ||
                                                              max_index_bytes < 128 || max_entries < 1 || max_entries > @max_search_entries
      check!
      original_ref, original_oid = head_ref_and_oid
      raise Error.new("Git reset requires an existing symbolic branch HEAD") unless original_ref &&
                                                                                    original_ref.starts_with?("refs/heads/") && original_oid
      reference = original_ref
      previous = original_oid
      target = History.resolve_commit(self, source, max_object_bytes, check)
      if mode.soft?
        if target != previous
          guard = -> do
            check.try &.call
            raise Error.new("Git reset HEAD changed") unless head_ref_and_oid == {reference, previous}
          end
          update_ref(reference, target, expected_oid: previous, log: log,
            max_object_bytes: max_object_bytes, check: guard)
        end
        return Reset::Result.new(reference, previous, target, mode, [] of String)
      end

      tree = read_commit(target, max_bytes: max_object_bytes, check: check).tree
      desired = IndexRestore.source_entries(self, tree, max_object_bytes: max_object_bytes,
        max_entries: max_entries, check: check)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git reset index entry budget exceeded") if current.size > max_entries
      edits = IndexRestore.edits(current, desired, nil)
      image = edits.empty? ? nil : @index.prepare_changes(edits,
        max_bytes: max_index_bytes, max_entries: max_entries, check: check)
      checksum = @index.snapshot_checksum(max_index_bytes)
      if target == previous && image.nil?
        return Reset::Result.new(reference, previous, target, mode, [] of String)
      end

      index_dir = DescriptorPath::Directory.open(@git_dir)
      locked = nil.as(IO::FileDescriptor?)
      ref_published = false
      index_published = false
      begin
        locked = index_dir.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard = -> do
          check.try &.call
          raise Error.new("Git reset HEAD changed") unless head_ref_and_oid == {reference, previous}
          raise Error.new("Git reset index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
        end
        guard.call
        if planned = image
          raise Error.new("Git reset index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          locked.write(planned.data.to_slice)
          locked.flush
          locked.fsync
        end
        guard.call
        if target != previous
          update_ref(reference, target, expected_oid: previous, log: log,
            max_object_bytes: max_object_bytes, check: guard)
          ref_published = true
        end
        if planned = image
          check.try &.call
          raise Error.new("Git reset index changed after ref publication") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          raise Error.new("Git reset index directory replaced") unless index_dir.attached_at?(@git_dir)
          index_dir.rename("index.lock", "index")
          index_published = true
          index_dir.sync
        end
        Reset::Result.new(reference, previous, target, mode, edits.map(&.path))
      rescue ex
        raise Reset::PartialPublication.new(ref_published, index_published, ex) if ref_published || index_published
        raise ex
      ensure
        if io = locked
          if index_dir.same_inode?("index.lock", io)
            index_dir.unlink("index.lock")
            index_dir.sync
          end
          io.close unless io.closed?
        end
        index_dir.close
      end
    end
  end
end
