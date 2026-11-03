require "set"

module Git
  # Bounded native revision parent selectors and commit-DAG merge bases.
  module Revision
    def self.resolve_commit(repository : Repository, expression : String,
                            max_bytes : Int32, check : Proc(Nil)?, *,
                            max_hops : Int32 = 4_096) : String
      raise ArgumentError.new("invalid Git revision hop budget") if max_hops < 1
      raise Error.new("Git revision selector rejected") if expression.empty? || expression.bytesize > 4_096
      first_op = expression.index(/[~^]/) || raise Error.new("invalid Git revision expression")
      source = expression.byte_slice(0, first_op)
      raise Error.new("invalid Git revision base") if source.empty?
      oid = History.resolve_commit(repository, source, max_bytes, check)
      position = first_op
      hops = 0
      while position < expression.bytesize
        check.try &.call
        op = expression.byte_at(position)
        position += 1
        if op == '^'.ord && position < expression.bytesize && expression.byte_at(position) == '{'.ord
          closing = expression.index('}', position) || raise Error.new("invalid Git peel suffix")
          kind = expression.byte_slice(position + 1, closing - position - 1)
          raise Error.new("unsupported Git peel type") unless kind.empty? || kind == "commit"
          position = closing + 1
          next
        end
        start = position
        while position < expression.bytesize
          digit = expression.byte_at(position)
          break unless digit >= '0'.ord && digit <= '9'.ord
          position += 1
        end
        count = if start == position
                  1
                else
                  expression.byte_slice(start, position - start).to_i64?
                end
        raise Error.new("invalid Git revision parent number") unless count && count >= 0 && count <= Int32::MAX
        raise Error.new("Git revision hop budget exceeded") if hops + count > max_hops
        if op == '~'.ord
          count.times do
            check.try &.call
            parent = repository.read_commit(oid, max_bytes: max_bytes, check: check).parents.first?
            raise Error.new("Git revision first parent missing") unless parent
            oid = parent
          end
        elsif op == '^'.ord
          if count > 0
            commit = repository.read_commit(oid, max_bytes: max_bytes, check: check)
            parent = commit.parents[count.to_i - 1]?
            raise Error.new("Git revision parent missing") unless parent
            oid = parent
          end
        else
          raise Error.new("unsupported Git revision operator")
        end
        hops += count.to_i
      end
      oid
    end
  end

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

    def self.merge_bases(repository : Repository, left : String, right : String, *,
                         max_nodes : Int32 = 16_384, max_commit_bytes : Int32 = 8_388_608,
                         check : Proc(Nil)? = nil) : Array(String)
      raise ArgumentError.new("invalid Git merge-base budgets") if max_nodes < 1 || max_commit_bytes < 128
      repository.check!
      left_oid = resolve_commit(repository, left, max_commit_bytes, check, max_hops: max_nodes)
      right_oid = resolve_commit(repository, right, max_commit_bytes, check, max_hops: max_nodes)
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
