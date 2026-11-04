require "set"

module Git
  # Bounded commit-DAG merge bases.
  module History
    protected def self.merge_bases(repository : Repository, left : String, right : String, *,
                                   max_nodes : Int32 = 16_384, max_commit_bytes : Int32 = 8_388_608,
                                   check : Proc(Nil)? = nil) : Array(String)
      raise ArgumentError.new("invalid Git merge-base budgets") if max_nodes < 1 || max_commit_bytes < 128
      repository.check!
      left_oid = resolve_commit(repository, left, max_commit_bytes, check)
      right_oid = resolve_commit(repository, right, max_commit_bytes, check)
      RevisionWalker.new(repository, check: check).merge_bases(left_oid, right_oid, max_nodes: max_nodes).sort
    end
  end

  class Repository
    # `git merge-base --all` semantics for a pair of revisions, including
    # criss-cross histories and unrelated roots. No worktree or ref writes.
    def merge_bases(left : String, right : String, *, max_nodes : Int32 = 16_384,
                    max_commit_bytes : Int32 = 8_388_608,
                    check : Proc(Nil)? = nil) : Array(String)
      History.merge_bases(self, left, right, max_nodes: max_nodes,
        max_commit_bytes: max_commit_bytes, check: check)
    end
  end
end
