module Git
  # Commit history: the revision walk behind log, rev-list and ancestry
  # queries.
  module History
    # How Repository#log orders commits.
    enum Order
      # Newest committer date first (`git log`).
      Date
      # Every commit before its parents, otherwise newest first
      # (`git log --topo-order`).
      Topological
    end

    # Commits from Repository#log: at most the requested number, whether
    # the range held more, and how many commits it held.
    struct Result
      getter commits : Array(Commit)
      getter? truncated : Bool
      getter scanned : Int32

      def initialize(@commits : Array(Commit), @truncated : Bool, @scanned : Int32)
      end
    end

    # :nodoc:
    def self.resolve_commit(repository : Repository, source : String,
                            max_bytes : Int32, check : Proc(Nil)?,
                            max_hops : Int32 = 4_096) : String
      raise Error.new("Git revision selector rejected") if source.empty? || source.bytesize > 4_096
      if source.index(/[~^]/)
        return Revision.resolve_commit(repository, source, max_bytes, check, max_hops: max_hops)
      end
      oid = if source == "HEAD"
              repository.head_ref_and_oid[1]
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
end
