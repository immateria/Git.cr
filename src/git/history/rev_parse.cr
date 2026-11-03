module Git
  class Repository
    PSEUDO_REFS = {"HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"}

    # Resolve a revision to an object ID, as `git rev-parse --verify` does,
    # for Git's everyday grammar: full or abbreviated (4+ hex) IDs, ref
    # names with Git's lookup rules, HEAD and the other pseudo-refs, @,
    # <ref>@{n}, <branch>@{upstream} (@{u}), ~N, ^N, ^{type}, ^{},
    # <rev>:<path> and :<path> / :<stage>:<path> (the index).
    def rev_parse(expression : String, *, max_object_bytes : Int32 = 268_435_456) : String
      check!
      raise Error.new("empty Git revision") if expression.empty?
      raise Error.new("Git revision too long") if expression.bytesize > 4096
      if expression.starts_with?(':')
        rest = expression.byte_slice(1)
        stage = 0
        if rest.bytesize >= 2 && rest[1] == ':' && ('0'..'3').includes?(rest[0])
          stage = rest[0].to_i
          rest = rest.byte_slice(2)
        end
        entry = @index.entries(Int32::MAX // 2) { nil }.find { |candidate| candidate.path == rest && candidate.stage == stage }
        raise Error.new("Git path #{rest} is not in the index at stage #{stage}") unless entry
        return entry.oid
      end
      if colon = top_level_colon(expression)
        tree_ish = rev_parse(expression.byte_slice(0, colon), max_object_bytes: max_object_bytes)
        path = expression.byte_slice(colon + 1)
        tree = peel_to(tree_ish, "tree", max_object_bytes)
        return tree if path.empty?
        return tree_path(tree, path, max_object_bytes)
      end
      position = base_end(expression)
      base = expression.byte_slice(0, position)
      oid = if base.empty? || base == "@"
              raise Error.new("invalid Git revision #{expression}") if base.empty? && !expression.byte_slice(position).starts_with?("@{")
              base == "@" ? "HEAD" : ""
            else
              base
            end
      current_ref = nil.as(String?)
      value = nil.as(String?)
      # @{...} suffixes apply to a ref name, so resolve them before peeling.
      suffix = expression.byte_slice(position)
      if suffix.starts_with?("@{")
        close = suffix.byte_index('}'.ord) || raise Error.new("invalid Git revision #{expression}")
        selector = suffix.byte_slice(2, close - 2)
        suffix = suffix.byte_slice(close + 1)
        ref = oid.empty? || oid == "HEAD" ? (head[0] || "HEAD") : (dwim_ref(oid) || raise Error.new("unknown Git revision #{oid}"))
        if {"u", "upstream"}.includes?(selector.downcase)
          raise Error.new("Git upstream needs a branch") unless ref.starts_with?("refs/heads/")
          upstream = branch_upstream(ref.byte_slice(11)) || raise Error.new("no upstream configured for #{ref.byte_slice(11)}")
          tracking = upstream_tracking_ref(upstream[0], upstream[1]) || raise Error.new("Git upstream #{upstream[1]} of #{upstream[0]} is not fetched")
          current_ref = tracking
          value = resolve_ref?(tracking) || raise Error.new("Git upstream #{tracking} does not exist")
        elsif (count = selector.to_i?) && count >= 0
          value = reflog_value(ref, count)
        else
          raise Error.new("unsupported Git revision selector @{#{selector}}")
        end
      else
        value = resolve_name(oid)
      end
      result = value || raise Error.new("unknown Git revision #{expression}")
      apply_suffixes(result, suffix, max_object_bytes, expression)
    end

    # `git rev-list <revisions>`: commits reachable from the positive
    # revisions and not from the negative ones (^A, A..B, A...B), newest
    # first by committer date.
    def rev_list(revisions : Array(String), *, limit : Int32? = nil,
                 check : Proc(Nil)? = nil) : Array(String)
      wants, haves = revision_sets(revisions)
      commits = Reachability::Walker.new(self, check: check).commits(wants, haves)
      limit ? commits.first(limit) : commits
    end

    # `git log <revisions>` as commit records (see rev_list).
    def log(revisions : Array(String) = ["HEAD"], *, limit : Int32 = 100,
            max_commit_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Array(Commit)
      rev_list(revisions, limit: limit, check: check).map do |oid|
        commit(oid, max_commit_bytes) { check.try &.call }
      end
    end

    # Commits only on left and only on right (`git rev-list --left-right
    # --count left...right`).
    def ahead_behind(left : String, right : String, *, check : Proc(Nil)? = nil) : {Int32, Int32}
      left_oid = peel_to(rev_parse(left), "commit", 8_388_608)
      right_oid = peel_to(rev_parse(right), "commit", 8_388_608)
      walker = Reachability::Walker.new(self, check: check)
      {walker.commits([left_oid], [right_oid]).size, Reachability::Walker.new(self, check: check).commits([right_oid], [left_oid]).size}
    end

    private def revision_sets(revisions : Array(String)) : {Array(String), Array(String)}
      wants = [] of String
      haves = [] of String
      commit_of = ->(text : String) { peel_to(rev_parse(text.empty? ? "HEAD" : text), "commit", 8_388_608) }
      revisions.each do |revision|
        if index = revision.index("...")
          left = commit_of.call(revision.byte_slice(0, index))
          right = commit_of.call(revision.byte_slice(index + 3))
          wants << left << right
          haves.concat(merge_bases(left, right))
        elsif index = revision.index("..")
          haves << commit_of.call(revision.byte_slice(0, index))
          wants << commit_of.call(revision.byte_slice(index + 2))
        elsif revision.starts_with?('^')
          haves << commit_of.call(revision.byte_slice(1))
        else
          wants << commit_of.call(revision)
        end
      end
      {wants.uniq, haves.uniq}
    end

    # A ref name expanded with Git's rules, or nil.
    def dwim_ref(name : String) : String?
      return name if PSEUDO_REFS.includes?(name) && (name == "HEAD" || File.file?(File.join(@git_dir, name)))
      Refspec::REV_PARSE_RULES.each do |rule|
        candidate = rule.sub("%s", name)
        next unless candidate.starts_with?("refs/") && RefName.valid?(candidate)
        begin
          return candidate if resolve_ref?(candidate) || symbolic_ref?(candidate)
        rescue Error
        end
      end
      nil
    end

    private def resolve_name(name : String) : String?
      if PSEUDO_REFS.includes?(name)
        return head[1] if name == "HEAD"
        path = File.join(@git_dir, name)
        return nil unless File.file?(path)
        first = File.read(path).lines.first?.try(&.split(/\s/).first?)
        return first ? ObjectId.valid!(first, @object_format) : nil
      end
      if name.bytesize == @object_format.hexsize && name.each_char.all?(&.hex?)
        oid = name.downcase
        return oid if has_object?(oid)
      end
      if ref = dwim_ref(name)
        return resolve_ref?(ref)
      end
      if name.bytesize >= 4 && name.bytesize < @object_format.hexsize && name.each_char.all?(&.hex?)
        matches = @object_database.prefix_matches(name.downcase, 2)
        raise Error.new("Git short object ID #{name} is ambiguous") if matches.size > 1
        return matches.first?
      end
      nil
    end

    private def apply_suffixes(oid : String, suffix : String, max_bytes : Int32, expression : String) : String
      position = 0
      current = oid
      bytes = suffix.to_slice
      while position < bytes.size
        op = bytes[position].unsafe_chr
        position += 1
        if op == '^' && position < bytes.size && bytes[position] == '{'.ord
          close = suffix.byte_index('}'.ord, position) || raise Error.new("invalid Git revision #{expression}")
          kind = suffix.byte_slice(position + 1, close - position - 1)
          position = close + 1
          current = case kind
                    when ""                             then Reachability::Walker.new(self, max_object_bytes: max_bytes).peel(current)[1]
                    when "commit", "tree", "blob", "tag" then peel_to(current, kind, max_bytes)
                    when "object"                       then current
                    else                                     raise Error.new("unsupported Git peel ^{#{kind}}")
                    end
          next
        end
        start = position
        while position < bytes.size && bytes[position].unsafe_chr.ascii_number?
          position += 1
        end
        count = start == position ? 1 : suffix.byte_slice(start, position - start).to_i
        case op
        when '~'
          count.times do
            current = peel_to(current, "commit", max_bytes)
            current = Reachability::Walker.new(self, max_object_bytes: max_bytes).commit_info(current).parents.first? ||
                      raise Error.new("Git revision #{expression} goes past a root commit")
          end
        when '^'
          current = peel_to(current, "commit", max_bytes)
          if count > 0
            parents = Reachability::Walker.new(self, max_object_bytes: max_bytes).commit_info(current).parents
            current = parents[count - 1]? || raise Error.new("Git revision #{expression} has no parent #{count}")
          end
        else
          raise Error.new("invalid Git revision #{expression}")
        end
      end
      current
    end

    # Follow tags (and from a commit to its tree) until an object of kind.
    private def peel_to(oid : String, kind : String, max_bytes : Int32) : String
      current = oid
      32.times do
        type, raw = object(current, max_bytes) { nil }
        return current if type == kind
        case type
        when "tag"
          target = raw.each_line.find(&.starts_with?("object ")) || raise Error.new("invalid Git tag #{current}")
          current = ObjectId.valid!(target.byte_slice(7).strip, @object_format)
        when "commit"
          raise Error.new("Git object #{oid} cannot be peeled to a #{kind}") unless kind == "tree"
          return Reachability.parse_commit(raw, @object_format).tree
        else
          raise Error.new("Git object #{oid} cannot be peeled to a #{kind}")
        end
      end
      raise Error.new("Git tag chain too long")
    end

    private def tree_path(tree : String, path : String, max_bytes : Int32) : String
      current = tree
      components = path.split('/').reject(&.empty?)
      components.each_with_index do |component, index|
        type, raw = object(current, max_bytes) { nil }
        raise Error.new("Git path #{path}: #{components[0...index].join('/')} is not a tree") unless type == "tree"
        found = nil.as(String?)
        Reachability.each_tree_entry(raw, @object_format) do |_, name, oid|
          found = oid if name == component
        end
        current = found || raise Error.new("Git path #{path} does not exist")
      end
      current
    end

    private def top_level_colon(expression : String) : Int32?
      depth = 0
      expression.to_slice.each_with_index do |byte, index|
        case byte
        when '{'.ord then depth += 1
        when '}'.ord then depth -= 1
        when ':'.ord then return index if depth == 0
        end
      end
      nil
    end

    private def base_end(expression : String) : Int32
      bytes = expression.to_slice
      bytes.each_with_index do |byte, index|
        return index if byte == '~'.ord || byte == '^'.ord
        return index if byte == '@'.ord && index + 1 < bytes.size && bytes[index + 1] == '{'.ord
      end
      bytes.size
    end

    private def reflog_value(ref : String, count : Int32) : String
      base = ref == "HEAD" ? @git_dir : @common
      path = File.join(base, "logs", ref)
      raise Error.new("Git ref #{ref} has no reflog") unless File.file?(path)
      lines = File.read(path).lines.reject(&.empty?)
      raise Error.new("Git log for #{ref} only has #{lines.size} entries") if count >= lines.size
      line = lines[lines.size - 1 - count]
      ObjectId.valid!(line.split(' ')[1], @object_format)
    end

    # The remote-tracking ref for a branch's upstream merge ref.
    def upstream_tracking_ref(remote_name : String, merge_ref : String) : String?
      return merge_ref if remote_name == "."
      remote = remote?(remote_name) || return nil
      remote.fetch_refspecs.each do |spec|
        next if spec.negative?
        if mapped = spec.map_source(merge_ref)
          return mapped
        end
      end
      nil
    end
  end
end
