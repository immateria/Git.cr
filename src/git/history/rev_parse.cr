module Git
  # :nodoc:
  module Revision
    # Follow tags (and from a commit to its tree) until an object of kind.
    protected def self.peel(repository : Repository, oid : String, kind : String, max_bytes : Int32 = 268_435_456) : String
      current = oid
      declared = nil.as(String?)
      32.times do
        type, raw = repository.object(current, max_bytes) { nil }
        raise Error.new("Git annotated tag target type mismatch") if declared && type != declared
        return current if type == kind
        case type
        when "tag"
          target = raw.each_line.find(&.starts_with?("object ")) || raise Error.new("invalid Git tag #{current}")
          declared = raw.each_line.find(&.starts_with?("type ")).try(&.byte_slice(5).strip)
          current = ObjectId.valid!(target.byte_slice(7).strip, repository.object_format)
        when "commit"
          raise Error.new("Git object #{oid} cannot be peeled to a #{kind}") unless kind == "tree"
          return History::CommitNode.parse(raw, repository.object_format).tree
        else
          raise Error.new("Git object #{oid} cannot be peeled to a #{kind}")
        end
      end
      raise Error.new("Git tag chain too long")
    end

    # The commits to include and exclude for rev-list style arguments:
    # A, ^A, A..B and A...B (the symmetric difference, excluding the merge
    # bases).
    protected def self.ranges(repository : Repository, revisions : Array(String)) : {Array(String), Array(String)}
      wants = [] of String
      haves = [] of String
      commit_of = ->(text : String) { peel(repository, repository.rev_parse(text.empty? ? "HEAD" : text), "commit") }
      revisions.each do |revision|
        if index = revision.byte_index("...")
          left = commit_of.call(revision.byte_slice(0, index))
          right = commit_of.call(revision.byte_slice(index + 3))
          wants << left << right
          haves.concat(repository.merge_bases(left, right))
        elsif index = revision.byte_index("..")
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

    # :nodoc:
    # Resolves Git's everyday revision grammar to object IDs (see
    # Repository#rev_parse).
    class Parser
      @walker : History::RevisionWalker? = nil

      def initialize(@repository : Repository, @max_object_bytes : Int32 = 268_435_456)
      end

      def parse(expression : String) : String
        raise Error.new("empty Git revision") if expression.empty?
        raise Error.new("Git revision too long") if expression.bytesize > 4096
        return search_commit_message(expression.byte_slice(2)) if expression.starts_with?(":/")
        return index_path(expression.byte_slice(1)) if expression.starts_with?(':')
        if colon = top_level_colon(expression)
          tree = Revision.peel(@repository, parse(expression.byte_slice(0, colon)), "tree", @max_object_bytes)
          path = expression.byte_slice(colon + 1)
          return path.empty? ? tree : tree_path(tree, path)
        end
        position = base_end(expression)
        base = expression.byte_slice(0, position)
        suffix = expression.byte_slice(position)
        if base.empty? && !suffix.starts_with?("@{")
          raise Error.new("invalid Git revision #{expression}")
        end
        name = base == "@" ? "HEAD" : base
        # @{...} applies to a ref name, so it is resolved before peeling.
        value = if suffix.starts_with?("@{")
                  close = suffix.byte_index('}'.ord) || raise Error.new("invalid Git revision #{expression}")
                  selector = suffix.byte_slice(2, close - 2)
                  suffix = suffix.byte_slice(close + 1)
                  resolve_selector(name, selector)
                else
                  resolve_name(name)
                end
        apply_suffixes(value || raise(Error.new("unknown Git revision #{expression}")), suffix, expression)
      end

      # A ref name expanded with Git's rules, or nil.
      def expand_ref(name : String) : String?
        if References::PSEUDO_REFS.includes?(name)
          return name if name == "HEAD" || File.file?(File.join(@repository.git_dir, name))
        end
        RefName::REV_PARSE_RULES.each do |rule|
          candidate = rule.sub("%s", name)
          next unless candidate.starts_with?("refs/") && RefName.valid?(candidate)
          begin
            return candidate if @repository.resolve_ref?(candidate) || @repository.symbolic_ref?(candidate)
          rescue Error
          end
        end
        nil
      end

      # The nth previous branch or commit checked out according to HEAD's
      # reflog (`@{-n}` or `git switch -`).
      def prior_checkout(nth : Int32) : String
        raise Error.new("invalid Git prior checkout count #{nth}") if nth < 1
        path = File.join(@repository.git_dir, "logs", "HEAD")
        raise Error.new("Git HEAD has no reflog") unless File.file?(path)
        found = 0
        File.read(path).lines.reverse_each do |line|
          next if line.empty?
          tab = line.byte_index('\t'.ord) || next
          message = line.byte_slice(tab + 1)
          next unless message.starts_with?("checkout: moving from ")
          rest = message.byte_slice(22)
          split = rest.byte_index(" to ") || next
          from = rest.byte_slice(0, split)
          next if from.empty?
          found += 1
          return from if found == nth
        end
        raise Error.new("Git reflog has fewer than #{nth} prior checkouts")
      end

      # :<path> or :<stage>:<path>.
      private def index_path(rest : String) : String
        stage = 0
        if rest.bytesize >= 2 && rest[1] == ':' && ('0'..'3').includes?(rest[0])
          stage = rest[0].to_i
          rest = rest.byte_slice(2)
        end
        entry = @repository.index_entries.find { |candidate| candidate.path == rest && candidate.stage == stage }
        raise Error.new("Git path #{rest} is not in the index at stage #{stage}") unless entry
        entry.oid
      end

      # <ref>@{upstream}, <ref>@{n} and @{-n}.
      private def resolve_selector(name : String, selector : String) : String
        if name.empty? && selector.starts_with?('-') && (nth = selector.byte_slice(1).to_i?) && nth >= 1
          target = prior_checkout(nth)
          return resolve_name(target) || raise Error.new("unknown Git revision #{target}")
        end
        ref = if name.empty? || name == "HEAD"
                @repository.head_ref_and_oid[0] || "HEAD"
              else
                expand_ref(name) || raise Error.new("unknown Git revision #{name}")
              end
        if {"u", "upstream"}.includes?(selector.downcase)
          raise Error.new("Git upstream needs a branch") unless ref.starts_with?("refs/heads/")
          branch = ref.byte_slice(11)
          remote_name, merge_ref = @repository.branch_upstream(branch) || raise Error.new("no upstream configured for #{branch}")
          tracking = @repository.upstream_tracking_ref(remote_name, merge_ref) || raise Error.new("Git upstream #{merge_ref} of #{remote_name} is not fetched")
          @repository.resolve_ref?(tracking) || raise Error.new("Git upstream #{tracking} does not exist")
        elsif (count = selector.to_i?) && count >= 0
          reflog_value(ref, count)
        else
          raise Error.new("unsupported Git revision selector @{#{selector}}")
        end
      end

      private def search_commit_message(query : String) : String
        raise Error.new("empty Git commit search query") if query.empty?
        regex = begin
          Regex.new(query)
        rescue ArgumentError
          Regex.new(Regex.escape(query))
        end
        tips = [] of String
        @repository.head_ref_and_oid[1].try { |oid| tips << oid }
        @repository.references("refs/").each do |ref|
          ref.oid.try do |oid|
            begin
              tips << Revision.peel(@repository, oid, "commit", @max_object_bytes)
            rescue Error
            end
          end
        end
        tips.uniq!
        walker.commits(tips, [] of String).each do |oid|
          raw = @repository.read_object(oid, max_bytes: @max_object_bytes)
          next unless raw.type.commit?
          separator = raw.data.byte_index("\n\n") || next
          message = raw.data.byte_slice(separator + 2, raw.data.bytesize - separator - 2)
          return oid if regex.matches?(message)
        end
        raise Error.new("no Git commit matches :/#{query}")
      end

      private def resolve_name(name : String) : String?
        format = @repository.object_format
        if References::PSEUDO_REFS.includes?(name)
          return @repository.head_ref_and_oid[1] if name == "HEAD"
          path = File.join(@repository.git_dir, name)
          return nil unless File.file?(path)
          first = File.read(path).lines.first?.try(&.split(/\s/).first?)
          return first ? ObjectId.valid!(first, format) : nil
        end
        if name.bytesize == format.hexsize && name.each_char.all?(&.hex?)
          oid = name.downcase
          return oid if @repository.has_object?(oid)
        end
        if ref = expand_ref(name)
          return @repository.resolve_ref?(ref)
        end
        if name.bytesize >= 4 && name.bytesize < format.hexsize && name.each_char.all?(&.hex?)
          matches = @repository.object_ids_with_prefix(name.downcase, limit: 2)
          raise Error.new("Git short object ID #{name} is ambiguous") if matches.size > 1
          return matches.first?
        end
        nil
      end

      private def apply_suffixes(oid : String, suffix : String, expression : String) : String
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
                      when ""                              then walker.peel(current)[1]
                      when "commit", "tree", "blob", "tag" then Revision.peel(@repository, current, kind, @max_object_bytes)
                      when "object"                        then current
                      else                                      raise Error.new("unsupported Git peel ^{#{kind}}")
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
              current = Revision.peel(@repository, current, "commit", @max_object_bytes)
              current = walker.commit_node(current).parents.first? ||
                        raise Error.new("Git revision #{expression} goes past a root commit")
            end
          when '^'
            current = Revision.peel(@repository, current, "commit", @max_object_bytes)
            if count > 0
              parents = walker.commit_node(current).parents
              current = parents[count - 1]? || raise Error.new("Git revision #{expression} has no parent #{count}")
            end
          else
            raise Error.new("invalid Git revision #{expression}")
          end
        end
        current
      end

      private def walker : History::RevisionWalker
        @walker ||= History::RevisionWalker.new(@repository, max_object_bytes: @max_object_bytes)
      end

      private def tree_path(tree : String, path : String) : String
        current = tree
        components = path.split('/').reject(&.empty?)
        components.each_with_index do |component, index|
          type, raw = @repository.object(current, @max_object_bytes) { nil }
          raise Error.new("Git path #{path}: #{components[0...index].join('/')} is not a tree") unless type == "tree"
          found = nil.as(String?)
          Tree.each_entry(raw, @repository.object_format) do |_, name, oid|
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
        base = ref == "HEAD" ? @repository.git_dir : @repository.common_dir
        path = File.join(base, "logs", ref)
        raise Error.new("Git ref #{ref} has no reflog") unless File.file?(path)
        lines = File.read(path).lines.reject(&.empty?)
        raise Error.new("Git log for #{ref} only has #{lines.size} entries") if count >= lines.size
        line = lines[lines.size - 1 - count]
        ObjectId.valid!(line.split(' ')[1], @repository.object_format)
      end
    end
  end

  class Repository
    # Resolve a revision to an object ID, as `git rev-parse --verify` does,
    # for Git's everyday grammar: full or abbreviated (4+ hex) IDs, ref
    # names with Git's lookup rules, HEAD and the other pseudo-refs, @,
    # <ref>@{n}, @{-n}, <branch>@{upstream} (@{u}), ~N, ^N, ^{type}, ^{},
    # :/text, <rev>:<path> and :<path> / :<stage>:<path> (the index).
    def rev_parse(expression : String, *, max_object_bytes : Int32 = 268_435_456) : String
      check!
      Revision::Parser.new(self, max_object_bytes).parse(expression)
    end

    # A short ref name expanded with Git's rules, or nil.
    protected def expand_ref(name : String) : String?
      Revision::Parser.new(self).expand_ref(name)
    end

    # `git rev-list <revisions>`: commits reachable from the positive
    # revisions and not from the negative ones (^A, A..B, A...B), newest
    # first by committer date.
    def rev_list(revisions : Array(String), *, limit : Int32? = nil,
                 check : Proc(Nil)? = nil) : Array(String)
      wants, haves = Revision.ranges(self, revisions)
      commits = History::RevisionWalker.new(self, check: check).commits(wants, haves)
      limit ? commits.first(limit) : commits
    end

    # `git log <revisions>`: commits reachable from the positive revisions
    # and not from the negative ones (^A, A..B, A...B), at most limit of
    # them, in order. An unborn HEAD contributes nothing. Raises when the
    # range holds more than max_commits commits.
    def log(revisions : Array(String) = ["HEAD"], *, limit : Int32 = 100,
            order : History::Order = History::Order::Default,
            max_commits : Int32 = 1_000_000, max_commit_bytes : Int32 = 8_388_608,
            check : Proc(Nil)? = nil) : History::Result
      raise ArgumentError.new("invalid Git log budgets") if limit < 0 || max_commits < 1 || max_commit_bytes < 128
      check!
      born = revisions.reject { |revision| revision == "HEAD" && head_ref_and_oid[1].nil? }
      return History::Result.new([] of Commit, false, 0) if born.empty?
      wants, haves = Revision.ranges(self, born)
      walker = History::RevisionWalker.new(self, check: check)
      oids = walker.commits(wants, haves, max_commits: max_commits)
      oids = walker.topological(oids, by_date: order.date?) unless order.default?
      commits = oids.first(limit).map { |oid| read_commit(oid, max_bytes: max_commit_bytes, check: check) }
      History::Result.new(commits, oids.size > limit, oids.size)
    end

    # Commits only on left and only on right (`git rev-list --left-right
    # --count left...right`).
    def ahead_behind(left : String, right : String, *, check : Proc(Nil)? = nil) : {Int32, Int32}
      left_oid = Revision.peel(self, rev_parse(left), "commit")
      right_oid = Revision.peel(self, rev_parse(right), "commit")
      {History::RevisionWalker.new(self, check: check).commits([left_oid], [right_oid]).size,
       History::RevisionWalker.new(self, check: check).commits([right_oid], [left_oid]).size}
    end
  end
end
