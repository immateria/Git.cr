require "set"

module Git
  # What `fsck` found. corrupt maps object IDs to the problem; missing
  # lists objects that something reachable names but the repository
  # lacks; unreachable lists stored objects nothing reachable names.
  record FsckReport, checked : Int32, corrupt : Hash(String, String),
    missing : Array(String), unreachable : Array(String) do
    def ok? : Bool
      corrupt.empty? && missing.empty?
    end
  end

  class Repository
    # `git fsck`: read every stored object (checking its envelope and ID),
    # check commit, tree and tag structure, then walk everything reachable
    # from refs, HEAD, reflogs and the index for missing objects. Objects
    # are only read, never repaired.
    def fsck(*, connectivity : Bool = true, max_object_bytes : Int32 = 268_435_456,
             check : Proc(Nil)? = nil) : FsckReport
      check!
      corrupt = {} of String => String
      stored = [] of String
      each_object_id { |oid| stored << oid }
      stored.sort!
      links = {} of String => Array(String)
      stored.each do |oid|
        check.try &.call
        begin
          kind, raw = object(oid, max_object_bytes) { check.try &.call }
          links[oid] = fsck_links(kind, raw)
        rescue ex : Git::Error
          corrupt[oid] = ex.message || ex.class.name
        end
      end
      missing = Set(String).new
      unreachable = [] of String
      if connectivity
        reached = Set(String).new
        pending = keep_tips.select { |oid| !corrupt.has_key?(oid) }
        shallow = shallow_commits
        until pending.empty?
          check.try &.call
          oid = pending.pop
          next unless reached.add?(oid)
          unless links.has_key?(oid)
            missing << oid unless corrupt.has_key?(oid)
            next
          end
          targets = links[oid]
          targets = [] of String if shallow.includes?(oid)
          targets.each { |target| pending << target unless reached.includes?(target) }
        end
        # The tree of a shallow commit is still required.
        shallow.each do |oid|
          next unless (raw = links[oid]?)
          raw.first?.try { |tree| missing << tree unless links.has_key?(tree) }
        end
        unreachable = stored.reject { |oid| reached.includes?(oid) || corrupt.has_key?(oid) }
      end
      FsckReport.new(stored.size, corrupt, missing.to_a.sort, unreachable)
    end

    # The objects an object names, after checking its structure: a commit's
    # tree first, then its parents; a tree's entries (not submodules); a
    # tag's target.
    private def fsck_links(kind : String, raw : String) : Array(String)
      case kind
      when "commit"
        info = Reachability.parse_commit(raw, @object_format)
        header_end = raw.index("\n\n") || raise Error.new("commit has no message separator")
        headers = raw.byte_slice(0, header_end)
        raise Error.new("commit does not start with a tree") unless headers.starts_with?("tree ")
        raise Error.new("commit has no author") unless headers.includes?("\nauthor ")
        raise Error.new("commit has no committer") unless headers.includes?("\ncommitter ")
        [info.tree] + info.parents
      when "tree"
        targets = [] of String
        previous = nil.as({String, String}?)
        Reachability.each_tree_entry(raw, @object_format) do |mode, name, oid|
          raise Error.new("tree has an invalid mode #{mode}") unless {"40000", "100644", "100755", "120000", "160000", "100664"}.includes?(mode)
          raise Error.new("tree has an invalid name #{name.inspect}") if name == "." || name == ".." || name.empty?
          current = {name, mode}
          if prior = previous
            raise Error.new("tree entries are not sorted") if tree_order(prior, current) >= 0
          end
          previous = current
          targets << oid unless mode == "160000"
        end
        targets
      when "tag"
        target = raw.each_line.find(&.starts_with?("object ")) || raise Error.new("tag has no object")
        raise Error.new("tag has no type") unless raw.each_line.any?(&.starts_with?("type "))
        [ObjectId.valid!(target.byte_slice(7).strip, @object_format)]
      else
        [] of String
      end
    end

    # Git's tree order: a directory sorts as if its name ended with '/'.
    private def tree_order(left : {String, String}, right : {String, String}) : Int32
      a = left[0] + (left[1] == "40000" ? "/" : "")
      b = right[0] + (right[1] == "40000" ? "/" : "")
      a.to_slice <=> b.to_slice
    end
  end
end
