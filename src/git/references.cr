module Git
  # A repository's references: listing (`git for-each-ref`), resolution,
  # compare-and-swap updates (`git update-ref`), symbolic refs
  # (`git symbolic-ref`) and packing (`git pack-refs`). Obtained from
  # Repository#refs; branches, tags and the recovery journal have their own
  # handles (Repository#branches, #tags, #recovery).
  struct References
    # Git's pseudo-refs, which live in the Git directory and are not under
    # refs/.
    PSEUDO_REFS = {"HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
                   "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"}

    def initialize(@repository : Repository)
    end

    # Every reference under prefix, loose refs shadowing packed ones,
    # sorted by name bytes.
    def list(prefix : String = "refs/", *, max_entries : Int32? = nil) : Array(Ref)
      if limit = max_entries
        @repository.references(prefix, max_entries: limit)
      else
        @repository.references(prefix)
      end
    end

    # The object ID a full reference name, HEAD or another pseudo-ref
    # (ORIG_HEAD, MERGE_HEAD, FETCH_HEAD's first line, ...) resolves to,
    # following symbolic refs, or nil when it does not exist or is unborn.
    def resolve?(name : String) : String?
      return @repository.head_ref_and_oid[1] if name == "HEAD"
      if PSEUDO_REFS.includes?(name)
        path = File.join(@repository.git_dir, name)
        return nil unless File.file?(path)
        line = File.open(path) { |io| io.gets(4_096) } || return nil
        return ObjectId.valid!(line.split(/\s/, 2).first, @repository.object_format)
      end
      @repository.resolve_ref?(name)
    end

    # The target of a symbolic ref, or nil when name is a direct ref or does
    # not exist.
    def symbolic_target?(name : String) : String?
      @repository.symbolic_ref?(name)
    end

    # A short ref name expanded with Git's lookup rules (`main` to
    # `refs/heads/main`), or nil when nothing matches.
    def expand(name : String) : String?
      @repository.expand_ref(name)
    end

    # Point name at new_oid if it currently resolves to expected_oid (nil
    # creates it and refuses an existing ref). HEAD is not updated
    # symbolically.
    def update(name : String, new_oid : String, *, expected_oid : String?,
               log : LogEntry? = nil, max_object_bytes : Int32 = 8_388_608,
               check : Proc(Nil)? = nil) : Nil
      @repository.update_ref(name, new_oid, expected_oid: expected_oid, log: log,
        max_object_bytes: max_object_bytes, check: check)
    end

    # Delete a direct ref if it currently resolves to expected_oid, with its
    # packed entry and reflog.
    def delete(name : String, *, expected_oid : String,
               max_packed_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Nil
      @repository.delete_ref(name, expected_oid: expected_oid,
        max_packed_bytes: max_packed_bytes, check: check)
    end

    # Apply creations, updates and deletions after one coordinated lock and
    # expected-OID preflight. Publication across files is not crash-atomic: a
    # late failure raises PartialPublication naming what was published (use
    # Repository#recovery for a journaled, resumable batch).
    def apply(changes : Array(Change), *, max_changes : Int32 = 64,
              max_object_bytes : Int32 = 8_388_608, max_packed_bytes : Int32 = 8_388_608,
              check : Proc(Nil)? = nil, after_publish : Proc(String, Nil)? = nil) : Nil
      @repository.change_refs(changes, max_changes: max_changes,
        max_object_bytes: max_object_bytes, max_packed_bytes: max_packed_bytes,
        check: check, after_publish: after_publish)
    end

    # Make name a symbolic ref to target. With expected_target the current
    # target must match; with create_only name must not exist.
    def set_symbolic(name : String, target : String, *, expected_target : String? = nil,
                     create_only : Bool = false, check : Proc(Nil)? = nil) : Nil
      @repository.set_symbolic_ref(name, target, expected_target: expected_target,
        create_only: create_only, check: check)
    end

    def delete_symbolic(name : String) : Nil
      @repository.delete_symbolic_ref(name)
    end

    # Point HEAD directly at a commit, leaving the index and worktree alone.
    def detach_head(oid : String) : Nil
      @repository.detach_head(oid)
    end

    # `git pack-refs`: move loose refs into packed-refs (all of them, or
    # only tags without all), pruning the loose files. Returns how many
    # were packed.
    def pack(*, all : Bool = true, prune : Bool = true, check : Proc(Nil)? = nil) : Int32
      @repository.pack_refs(all: all, prune: prune, check: check)
    end

    # The durable, resumable form of ref (and index) changes: each batch is
    # journaled under a caller-chosen ID before publication, so an
    # interrupted batch can be resumed. Obtained from Repository#recovery.
    struct Recovery
      def initialize(@repository : Repository)
      end

      # Journal and apply a ref batch, replaying its reflog lines after
      # the refs are published.
      def apply(changes : Array(Change), *, id : String,
                max_object_bytes : Int32 = 8_388_608, max_packed_bytes : Int32 = 8_388_608,
                check : Proc(Nil)? = nil, after_publish : Proc(String, Nil)? = nil,
                after_reflog : Proc(String, Nil)? = nil) : Nil
        @repository.change_refs_recoverably(changes, id: id, max_object_bytes: max_object_bytes,
          max_packed_bytes: max_packed_bytes, check: check, after_publish: after_publish,
          after_reflog: after_reflog)
      end

      # Journal index edits together with a ref batch. Objects must already
      # exist. Resuming completes whichever side was not yet published; the
      # two are not published all-or-nothing.
      def apply(edits : Array(Index::Edit), changes : Array(Change), *, id : String,
                max_index_bytes : Int32 = 8_388_608, max_index_entries : Int32 = 100_000,
                max_object_bytes : Int32 = 8_388_608, max_packed_bytes : Int32 = 8_388_608,
                check : Proc(Nil)? = nil, after_index_publish : Proc(Nil)? = nil,
                after_publish : Proc(String, Nil)? = nil,
                after_reflog : Proc(String, Nil)? = nil) : Nil
        @repository.change_index_and_refs_recoverably(edits, changes, id: id,
          max_index_bytes: max_index_bytes, max_index_entries: max_index_entries,
          max_object_bytes: max_object_bytes, max_packed_bytes: max_packed_bytes,
          check: check, after_index_publish: after_index_publish,
          after_publish: after_publish, after_reflog: after_reflog)
      end

      # Commit the index as edited (built from the prepared image, not a
      # second read of the index) and journal the image with the branch
      # update. Returns the new commit's ID.
      def commit(edits : Array(Index::Edit), *, id : String, author : Signature,
                 committer : Signature, message : String, allow_empty : Bool = false,
                 max_index_bytes : Int32 = 8_388_608, max_index_entries : Int32 = 100_000,
                 max_object_bytes : Int64 = 8_388_608_i64,
                 max_staged_object_bytes : Int32 = 8_388_608,
                 check : Proc(Nil)? = nil, after_index_publish : Proc(Nil)? = nil,
                 after_publish : Proc(String, Nil)? = nil,
                 after_reflog : Proc(String, Nil)? = nil) : String
        @repository.commit_index_changes_recoverably(edits, id: id, author: author,
          committer: committer, message: message, allow_empty: allow_empty,
          max_index_bytes: max_index_bytes, max_index_entries: max_index_entries,
          max_object_bytes: max_object_bytes, max_staged_object_bytes: max_staged_object_bytes,
          check: check, after_index_publish: after_index_publish,
          after_publish: after_publish, after_reflog: after_reflog)
      end

      # Finish an interrupted journal, publishing whatever of its index image,
      # refs and reflogs is still outstanding. The caller decides that
      # resuming is authorized; clear_abandoned_locks additionally needs an
      # exclusive maintenance window.
      def resume(id : String, *, clear_abandoned_locks : Bool = false,
                 max_object_bytes : Int32 = 8_388_608, max_packed_bytes : Int32 = 8_388_608,
                 check : Proc(Nil)? = nil, after_index_publish : Proc(Nil)? = nil,
                 after_publish : Proc(String, Nil)? = nil,
                 after_reflog : Proc(String, Nil)? = nil) : Nil
        @repository.recover_index_and_refs(id, clear_abandoned_locks: clear_abandoned_locks,
          max_object_bytes: max_object_bytes, max_packed_bytes: max_packed_bytes,
          check: check, after_index_publish: after_index_publish,
          after_publish: after_publish, after_reflog: after_reflog)
      end

      # IDs of journals that have not finished.
      def pending : Array(String)
        @repository.pending_ref_recoveries
      end

      # IDs of finished journals whose finalization receipt remains.
      def pending_finalizations : Array(String)
        @repository.pending_ref_finalizations
      end

      def finish_finalization(id : String) : Nil
        @repository.finish_ref_finalization(id)
      end
    end
  end

  class Repository
    # The repository's references.
    def refs : References
      References.new(self)
    end

    # The journal for resumable ref and index changes.
    def recovery : References::Recovery
      References::Recovery.new(self)
    end
  end
end
