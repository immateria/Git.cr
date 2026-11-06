module Git
  class Repository
    # Opt-in durable forward-recoverable ref batch. Reflog updates are
    # journaled and replayed after ref publication using exact byte prefixes.
    # The given stable
    # identifier is needed to resume after a process interruption.
    protected def change_refs_recoverably(changes : Array(References::Change), *, id : String,
                                          max_object_bytes : Int32 = 8_388_608,
                                          max_packed_bytes : Int32 = 8_388_608,
                                          check : Proc(Nil)? = nil,
                                          after_publish : Proc(String, Nil)? = nil,
                                          after_reflog : Proc(String, Nil)? = nil) : Nil
      References::Recovery.run(@metadata, @object_format, id, changes, after_reflog) do |logless|
        change_refs(logless, max_object_bytes: max_object_bytes,
          max_packed_bytes: max_packed_bytes, check: check,
          after_publish: after_publish)
      end
    end

    # Prepare index edits and publish them with a ref redo intent in one
    # durable journal. Objects/commit OIDs must already exist. Recovery may
    # observe the index or refs independently published, and forward-completes
    # the other surface, but does not provide all-or-nothing visibility.
    protected def change_index_and_refs_recoverably(edits : Array(Index::Edit), changes : Array(References::Change), *,
                                                    id : String, max_index_bytes : Int32 = 8_388_608,
                                                    max_index_entries : Int32 = 100_000,
                                                    max_object_bytes : Int32 = 8_388_608,
                                                    max_packed_bytes : Int32 = 8_388_608,
                                                    check : Proc(Nil)? = nil,
                                                    after_index_publish : Proc(Nil)? = nil,
                                                    after_publish : Proc(String, Nil)? = nil,
                                                    after_reflog : Proc(String, Nil)? = nil) : Nil
      raise Error.new("Git recoverable index byte budget exceeded") if max_index_bytes > References::Recovery::MAX_INDEX_IMAGE_BYTES
      image = @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_index_entries, check: check)
      publish_index_ref_image(image, changes, id: id,
        max_object_bytes: max_object_bytes, max_packed_bytes: max_packed_bytes,
        check: check, after_index_publish: after_index_publish,
        after_publish: after_publish, after_reflog: after_reflog)
    end

    # Build a real commit from the exact prepared staged image (not a second
    # racy index read), then journal that image together with the branch CAS.
    # The immutable tree and commit objects precede the redo record, and may
    # remain unreachable if the operation fails before journal publication.
    protected def commit_index_changes_recoverably(edits : Array(Index::Edit), *, id : String,
                                                   author : Signature, committer : Signature,
                                                   message : String, allow_empty : Bool = false,
                                                   max_index_bytes : Int32 = 8_388_608,
                                                   max_index_entries : Int32 = 100_000,
                                                   max_object_bytes : Int64 = 8_388_608_i64,
                                                   max_staged_object_bytes : Int32 = 8_388_608,
                                                   check : Proc(Nil)? = nil,
                                                   after_index_publish : Proc(Nil)? = nil,
                                                   after_publish : Proc(String, Nil)? = nil,
                                                   after_reflog : Proc(String, Nil)? = nil) : String
      check!
      raise Error.new("Git recoverable index byte budget exceeded") if max_index_bytes > References::Recovery::MAX_INDEX_IMAGE_BYTES
      branch, previous = head_ref_and_oid
      raise Error.new("native commit requires a symbolic branch HEAD") unless branch && branch.starts_with?("refs/heads/")
      plan = @index.prepare_changes_plan(edits, max_bytes: max_index_bytes,
        max_entries: max_index_entries, check: check)
      if previous.nil? && plan.entries.empty? && !allow_empty
        raise Error.new("nothing staged to commit")
      end
      raise ArgumentError.new("invalid staged object read budget") if max_staged_object_bytes < 128 ||
                                                                      max_staged_object_bytes > Int32::MAX - 256
      builder = Index::TreeBuilder.new
      plan.entries.each do |entry|
        check.try &.call
        builder.add(entry)
        # Gitlink OIDs belong to a different repository; ordinary staged
        # entries must resolve to actual local blobs, not dangling tree or
        # commit OIDs that would create a broken commit graph.
        next if entry.mode == "160000"
        kind, _ = @object_database.object(entry.oid, max_staged_object_bytes) { check.try &.call }
        raise Error.new("Git staged entry does not name a blob") unless kind == "blob"
      end
      tree = builder.write(self, max_bytes: max_object_bytes, check: check)
      if previous && !allow_empty
        original = read_commit(previous, max_bytes: max_index_bytes, check: check)
        raise Error.new("nothing staged to commit") if original.tree == tree
      end
      parents = previous ? [previous] : [] of String
      oid = write_commit(tree: tree, parents: parents, author: author,
        committer: committer, message: message, max_bytes: max_object_bytes,
        check: check)
      subject = message.split("\n", 2).first
      prefix = previous ? "commit: " : "commit (initial): "
      log = References::LogEntry.new(committer, "#{prefix}#{subject}")
      changes = [] of References::Change
      changes << References::Update.new(branch, oid, previous, log)
      publish_index_ref_image(plan.image, changes, id: id,
        max_object_bytes: {max_object_bytes, 8_388_608_i64}.min.to_i,
        check: check, after_index_publish: after_index_publish,
        after_publish: after_publish, after_reflog: after_reflog)
      oid
    end

    private def publish_index_ref_image(image : Index::Image, changes : Array(References::Change), *,
                                        id : String, max_object_bytes : Int32 = 8_388_608,
                                        max_packed_bytes : Int32 = 8_388_608,
                                        check : Proc(Nil)? = nil,
                                        after_index_publish : Proc(Nil)? = nil,
                                        after_publish : Proc(String, Nil)? = nil,
                                        after_reflog : Proc(String, Nil)? = nil) : Nil
      References::Recovery.run(@metadata, @object_format, id, changes, after_reflog,
        index_image: image, index_store: @index, index_check: check,
        after_index_publish: after_index_publish) do |logless|
        change_refs(logless, max_object_bytes: max_object_bytes,
          max_packed_bytes: max_packed_bytes, check: check, after_publish: after_publish)
      end
    end

    # Requires explicit caller approval. Abandoned .lock removal additionally
    # requires independent exclusive maintenance authority.
    protected def recover_index_and_refs(id : String, *, clear_abandoned_locks : Bool = false,
                                         max_object_bytes : Int32 = 8_388_608,
                                         max_packed_bytes : Int32 = 8_388_608,
                                         check : Proc(Nil)? = nil,
                                         after_index_publish : Proc(Nil)? = nil,
                                         after_publish : Proc(String, Nil)? = nil,
                                         after_reflog : Proc(String, Nil)? = nil) : Nil
      References::Recovery.resume(@metadata, @object_format, id,
        clear_abandoned_locks: clear_abandoned_locks, check: check,
        index_store: @index, index_check: check,
        after_index_publish: after_index_publish,
        after_reflog: after_reflog) do |pending|
        change_refs(pending, max_object_bytes: max_object_bytes,
          max_packed_bytes: max_packed_bytes, check: check, after_publish: after_publish)
      end
    end

    protected def pending_ref_recoveries : Array(String)
      References::Recovery.list(@metadata)
    end

    # Orphaned finalization receipts are distinct from unfinished redo journals.
    # Cleanup never removes a foreign lock and requires exact expected state.
    protected def pending_ref_finalizations : Array(String)
      References::Recovery.pending_finalizations(@metadata)
    end

    protected def finish_ref_finalization(id : String) : Nil
      References::Recovery.finish_finalization(@metadata, @object_format, id)
    end
  end
end
