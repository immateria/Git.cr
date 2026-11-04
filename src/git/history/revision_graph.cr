require "set"

module Git
  # Bounded commit-DAG merge bases.
  module History
    # Computes the reachable ancestors of a commit using bounded iterative
    # traversal; `cache` deduplicates immutable commit objects across roots.
    private def self.ancestors(repository : Repository, root : String,
                               cache : Hash(String, Commit), max_nodes : Int32,
                               max_bytes : Int32, check : Proc(Nil)?) : Set(String)
      seen = Set(String).new
      stack = [root]
      until stack.empty?
        check.try &.call
        oid = stack.pop
        next unless seen.add?(oid)
        commit = cache[oid]? || begin
          raise Error.new("Git merge-base node budget exceeded") if cache.size >= max_nodes
          loaded = repository.read_commit(oid, max_bytes: max_bytes, check: check)
          cache[oid] = loaded
          loaded
        end
        commit.parents.each { |parent| stack << parent }
      end
      seen
    end

    protected def self.merge_bases(repository : Repository, left : String, right : String, *,
                                   max_nodes : Int32 = 16_384, max_commit_bytes : Int32 = 8_388_608,
                                   check : Proc(Nil)? = nil) : Array(String)
      raise ArgumentError.new("invalid Git merge-base budgets") if max_nodes < 1 || max_commit_bytes < 128
      repository.check!
      left_oid = resolve_commit(repository, left, max_commit_bytes, check)
      right_oid = resolve_commit(repository, right, max_commit_bytes, check)
      cache = {} of String => Commit
      left_set = ancestors(repository, left_oid, cache, max_nodes, max_commit_bytes, check)
      right_set = ancestors(repository, right_oid, cache, max_nodes, max_commit_bytes, check)
      common = left_set & right_set
      return [] of String if common.empty?
      # Every ancestor of a common commit is common as well. Therefore a
      # common node is a best base exactly when no other common node lists
      # it as a parent. Multiple maximal nodes are valid criss-cross bases.
      dominated = Set(String).new
      common.each do |oid|
        check.try &.call
        cache[oid].parents.each { |parent| dominated.add(parent) if common.includes?(parent) }
      end
      common.reject { |oid| dominated.includes?(oid) }.to_a.sort
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
