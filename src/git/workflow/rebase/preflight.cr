module Git
  class Repository
    private def rebase_plan(head_oid : String, upstream_oid : String, *,
                            max_commits : Int32, max_graph_nodes : Int32,
                            max_object_bytes : Int32,
                            check : Proc(Nil)?) : {String, Array(String)}
      bases = merge_bases(head_oid, upstream_oid, max_nodes: max_graph_nodes,
        max_commit_bytes: max_object_bytes, check: check)
      raise Error.new("Git rebase requires related histories") if bases.empty?
      raise Error.new("Git rebase multiple merge bases unsupported") unless bases.size == 1
      base = bases.first
      reverse = [] of String
      cursor = head_oid
      until cursor == base
        check.try &.call
        raise Error.new("Git rebase commit budget exceeded") if reverse.size >= max_commits
        entry = read_commit(cursor, max_bytes: max_object_bytes, check: check)
        raise Error.new("Git rebase merge commits unsupported") if entry.parents.size > 1
        parent = entry.parents.first? || raise Error.new("Git rebase base is not on the first-parent chain")
        reverse << cursor
        cursor = parent
      end
      {base, reverse.reverse}
    end

    private def rebase_preflight_clean!(head_oid : String, *,
                                        max_object_bytes : Int32,
                                        max_index_bytes : Int32,
                                        max_total_bytes : Int64,
                                        max_entries : Int32,
                                        check : Proc(Nil)?) : Nil
      tree = read_commit(head_oid, max_bytes: max_object_bytes, check: check).tree
      expected = Checkout.tree_files(self, tree, max_object_bytes: max_object_bytes,
        max_files: max_entries, check: check, allow_symlinks: true)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git rebase requires index equal to HEAD") unless current.size == expected.size && current.all? do |entry|
                                                                          entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                          expected[entry.path]?.try { |state| state.mode == entry.mode && state.oid == entry.oid } == true
                                                                        end
      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
    end
  end
end
