module Git
  class Repository
    # Create a two-parent merge commit only after all conflicts have been
    # resolved into stage-zero index entries. The branch remains unchanged
    # while conflicts are present; a stale HEAD or rewritten MERGE_HEAD fails.
    def merge_continue(*, author : Signature, committer : Signature,
                       message : String? = nil, max_object_bytes : Int32 = 8_388_608,
                       max_index_bytes : Int32 = 8_388_608,
                       check : Proc(Nil)? = nil) : String
      require_worktree!
      branch, ours, theirs = merge_state? || raise Error.new("no Git merge in progress")
      raise Error.new("Git merge HEAD changed since start") unless head == {branch, ours}
      snapshot = @index.snapshot_checksum(max_index_bytes)
      raise Error.new("Git merge has unresolved paths") if @index.entries(max_index_bytes) { check.try &.call }.any? { |entry| entry.stage != 0 }
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        text = message || merge_read_metadata?(admin, "MERGE_MSG") || raise Error.new("Git merge message missing")
        raise Error.new("invalid Git merge commit message") if text.empty? || text.includes?('\0')
        tree = write_index_tree(max_index_bytes: max_index_bytes,
          max_tree_bytes: max_object_bytes, check: check)
        oid = write_commit(tree: tree, parents: [ours, theirs], author: author,
          committer: committer, message: text, max_bytes: max_object_bytes, check: check)
        checked = -> do
          check.try &.call
          raise Error.new("Git merge changed during commit") unless head == {branch, ours} &&
                                                                    merge_state? == {branch, ours, theirs} &&
                                                                    @index.snapshot_checksum(max_index_bytes) == snapshot
        end
        checked.call
        begin
          update_ref(branch, oid, expected_oid: ours,
            log: References::LogEntry.new(committer, "merge #{theirs}: #{text.lines.first? || ""}"),
            max_object_bytes: max_object_bytes, check: checked)
        rescue ex
          raise Merge::PartialCommit.new(oid, ex) if head == {branch, oid}
          raise ex
        end
        # A late error leaves merge metadata in place. Manual inspection is
        # necessary; a subsequent continue must refuse the moved HEAD.
        begin
          merge_clear_metadata!(admin, branch, ours, theirs)
        rescue ex
          raise Merge::PartialCommit.new(oid, ex)
        end
        oid
      ensure
        admin.close
      end
    end
  end
end
