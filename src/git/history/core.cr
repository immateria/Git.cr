module Git
  # A native bounded commit-DAG traversal, not a Git log CLI emulation.
  # Roots are exact OIDs, HEAD, or fully qualified refs. Revision operators,
  # reflog selectors, path filters, and commit-date ordering are not inferred.
  module History
    record Result, commits : Array(Commit), truncated : Bool, scanned : Int32

    def self.walk(repository : Repository, starts : Array(String) = ["HEAD"], *,
                  limit : Int32 = 100, max_nodes : Int32 = 4_096,
                  max_commit_bytes : Int32 = 8_388_608,
                  check : Proc(Nil)? = nil) : Result
      raise ArgumentError.new("invalid Git history budgets") if limit < 0 || max_nodes < 1 ||
                                                                max_commit_bytes < 128 || starts.size > 64
      repository.check!
      roots = [] of String
      starts.each do |start|
        check.try &.call
        next if start == "HEAD" && repository.head[1].nil?
        root = resolve_commit(repository, start, max_commit_bytes, check)
        roots << root unless roots.includes?(root)
      end
      # Explicit exit frames keep the traversal bounded in stack usage and
      # produce a child-before-parent topological order, including merges.
      # Visit secondary parents first so reversing postorder gives the first
      # parent preference. No wall-clock/date sorting is implied.
      stack = [] of {String, Bool}
      roots.reverse_each { |oid| stack << {oid, false} }
      active = Set(String).new
      visited = Set(String).new
      postorder = [] of Commit
      loaded = {} of String => Commit
      discovered = 0
      until stack.empty?
        check.try &.call
        oid, finish = stack.pop
        if finish
          raise Error.new("invalid Git history traversal state") unless active.delete(oid)
          visited.add(oid)
          postorder << loaded[oid]
          next
        end
        next if visited.includes?(oid)
        raise Error.new("Git commit history contains a cycle") if active.includes?(oid)
        discovered += 1
        raise Error.new("Git history node budget exceeded") if discovered > max_nodes
        active.add(oid)
        commit = repository.commit(oid, max_commit_bytes) { check.try &.call }
        loaded[oid] = commit
        stack << {oid, true}
        # Exact parent sequence from the commit body is preserved; a second
        # reference to a completed ancestor is skipped by visited.
        commit.parents.each { |parent| stack << {parent, false} }
      end
      ordered = postorder.reverse
      Result.new(ordered.first(limit), ordered.size > limit, ordered.size)
    end

    def self.resolve_commit(repository : Repository, source : String,
                            max_bytes : Int32, check : Proc(Nil)?,
                            max_hops : Int32 = 4_096) : String
      raise Error.new("Git revision selector rejected") if source.empty? || source.bytesize > 4_096
      if source.index(/[~^]/)
        return Revision.resolve_commit(repository, source, max_bytes, check, max_hops: max_hops)
      end
      oid = if source == "HEAD"
              repository.head[1]
            elsif source.starts_with?("refs/")
              repository.resolve_ref?(source)
            elsif source.bytesize == repository.object_format.hexsize
              ObjectId.valid!(source, repository.object_format)
            elsif RefName.valid?("refs/heads/#{source}")
              # Git's short-name precedence includes tags before branches.
              # This is a deliberately narrow branch/tag DWIM form, not the
              # full extended rev-parse or upstream tracking grammar.
              repository.resolve_ref?("refs/tags/#{source}") ||
                repository.resolve_ref?("refs/heads/#{source}")
            else
              raise Error.new("unsupported Git revision selector")
            end
      raise Error.new("Git revision could not be resolved") unless oid
      seen = Set(String).new
      expected_kind = nil.as(String?)
      16.times do
        check.try &.call
        raise Error.new("Git annotated tag cycle") unless seen.add?(oid)
        kind, content = repository.object(oid, max_bytes) { check.try &.call }
        raise Error.new("Git annotated tag target type mismatch") if expected_kind && kind != expected_kind
        return oid if kind == "commit"
        raise Error.new("Git revision does not resolve to a commit") unless kind == "tag"
        separator = content.index("\n\n") || raise Error.new("invalid Git annotated tag")
        headers = content.byte_slice(0, separator)
        target = nil.as(String?)
        target_type = nil.as(String?)
        headers.each_line do |line|
          target = ObjectId.valid!(line.byte_slice(7).strip, repository.object_format) if line.starts_with?("object ")
          target_type = line.byte_slice(5).strip if line.starts_with?("type ")
        end
        raise Error.new("invalid Git annotated tag target") unless target && {"tag", "commit"}.includes?(target_type)
        oid = target
        expected_kind = target_type
      end
      raise Error.new("Git annotated tag nesting limit exceeded")
    end
  end

  class Repository
    # Traverse all parents of commits reachable from the supplied exact roots.
    # The result is topological (child before all parents), deterministic for
    # fixed commit objects and root order, and bounded by max_nodes. A smaller
    # limit truncates output but still validates the reachable DAG.
    def history(starts : Array(String) = ["HEAD"], *, limit : Int32 = 100,
                max_nodes : Int32 = 4_096,
                max_commit_bytes : Int32 = 8_388_608,
                check : Proc(Nil)? = nil) : History::Result
      History.walk(self, starts, limit: limit, max_nodes: max_nodes,
        max_commit_bytes: max_commit_bytes, check: check)
    end
  end
end
