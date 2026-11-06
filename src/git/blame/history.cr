module Git
  struct Blame
    private record Entry, mode : String, oid : String
    private record Node, tree : String, parents : Array(String),
      author : Signature, committer : Signature
    private record Origin, oid : String, path : String, entry : Entry

    # One read-only object/cache authority for a blame query. Rename scoring
    # uses this same reader, so candidate blobs cannot bypass its byte limit.
    private class History
      getter max_lines : Int32
      @objects = {} of String => {String, String}
      @nodes = {} of String => Node
      @trees = {} of String => Hash(String, Entry)
      @lines = {} of String => Array(String)
      @origins = {} of {String, String, String, Bool} => Origin?
      @bytes = 0_i64
      @line_count = 0_i64
      @shallow : Set(String)
      @similarity : TreeDiff::Similarity

      def initialize(@repository : Repository, @max_history_nodes : Int32,
                     @max_object_bytes : Int32, @max_total_bytes : Int64,
                     @max_entries : Int32, @max_lines : Int32,
                     @work : TextDiff::Work, @check : Proc(Nil)?)
        @shallow = @repository.shallow_commits
        @similarity = TreeDiff::Similarity.new(@check) { |oid| blob(oid) }
      end

      def scanned : Int32
        @nodes.size
      end

      private def object(oid : String, expected : String) : String
        @check.try &.call
        stored = @objects[oid]? || begin
          kind, raw = @repository.object(oid, @max_object_bytes) { @check.try &.call }
          @bytes += raw.bytesize
          raise Error.new("Git blame total byte budget exceeded") if @bytes > @max_total_bytes
          @objects[oid] = {kind, raw}
        end
        raise Error.new("Git blame expected #{expected}") unless stored[0] == expected
        stored[1]
      end

      def blob(oid : String) : String
        object(oid, "blob")
      end

      def node(oid : String) : Node
        @nodes[oid]? || begin
          raise Error.new("Git blame history budget exceeded") if @nodes.size >= @max_history_nodes
          raw = object(oid, "commit")
          separator = raw.byte_index("\n\n") || raise Error.new("Git blame commit missing header separator")
          graph = Git::History::CommitNode.parse(raw, @repository.object_format)
          author = committer = ""
          encoding = nil.as(String?)
          raw.byte_slice(0, separator).each_line do |line|
            @check.try &.call
            case
            when line.starts_with?("author ")    then author = line.byte_slice(7)
            when line.starts_with?("committer ") then committer = line.byte_slice(10)
            when line.starts_with?("encoding ")  then encoding = line.byte_slice(9)
            end
          end
          if encoding && !{"utf-8", "utf8"}.includes?(encoding.downcase)
            author = utf8(author, encoding)
            committer = utf8(committer, encoding)
          end
          parents = @shallow.includes?(oid) ? [] of String : graph.parents
          @nodes[oid] = Node.new(graph.tree, parents,
            Signature.parse_git_header(author), Signature.parse_git_header(committer))
        end
      end

      private def utf8(value : String, encoding : String) : String
        String.new(value.to_slice, encoding)
      rescue ArgumentError
        value
      end

      private def entries(oid : String) : Hash(String, Entry)
        @trees[oid]? || begin
          raw = object(oid, "tree")
          values = {} of String => Entry
          Tree.each_entry(raw, @repository.object_format) do |mode, name, target|
            @check.try &.call
            PathBytes.validate_tree_name!(name)
            raise Error.new("Git blame duplicate tree entry") if values.has_key?(name)
            raise Error.new("Git blame tree entry budget exceeded") if values.size >= @max_entries
            unless {"40000", "100644", "100755", "120000", "160000"}.includes?(mode)
              raise Error.new("Git blame unsupported tree mode")
            end
            values[name] = Entry.new(mode, target)
          end
          @trees[oid] = values
        end
      end

      def lookup(tree : String, path : String) : Entry?
        parts = path.split('/')
        parts.each_with_index do |name, index|
          entry = entries(tree)[name]?
          return nil unless entry
          return entry if index == parts.size - 1
          return nil unless entry.mode == "40000"
          tree = entry.oid
        end
        nil
      end

      def lines(entry : Entry) : Array(String)
        @lines[entry.oid]? || begin
          raw = blob(entry.oid)
          result = [] of String
          position = 0
          while position < raw.bytesize
            @check.try &.call if result.size % 1024 == 0
            raise Error.new("Git blame line budget exceeded") if @line_count >= @max_lines
            stop = raw.byte_index(10, position).try { |offset| offset + 1 } || raw.bytesize
            result << raw.byte_slice(position, stop - position)
            @line_count += 1
            position = stop
          end
          @lines[entry.oid] = result
        end
      end

      def regular_or_symlink?(entry : Entry) : Bool
        {"100644", "100755", "120000"}.includes?(entry.mode)
      end

      private def same_kind?(left : Entry, right : Entry) : Bool
        regular_or_symlink?(left) && regular_or_symlink?(right) &&
          (left.mode == "120000") == (right.mode == "120000")
      end

      def parent_origin(parent : String, current : Origin, follow_renames : Bool) : Origin?
        key = {parent, current.oid, current.path, follow_renames}
        return @origins[key] if @origins.has_key?(key)
        before = node(parent)
        entry = lookup(before.tree, current.path)
        # A directory at this path is not a predecessor file. Its removed
        # descendants may still provide a whole-file rename into this path.
        entry = nil if entry.try(&.mode) == "40000"
        origin = if entry
                   same_kind?(entry, current.entry) ? Origin.new(parent, current.path, entry) : nil
                 elsif follow_renames
                   rename(parent, before.tree, current)
                 end
        @origins[key] = origin
      end

      private def files(tree : String) : Hash(String, Entry)
        result = {} of String => Entry
        stack = [{tree, "", 0}]
        count = 0
        until stack.empty?
          oid, prefix, depth = stack.pop
          raise Error.new("Git blame tree depth budget exceeded") if depth > Metadata::MAX_DEPTH
          entries(oid).each do |name, entry|
            @work.tick
            count += 1
            raise Error.new("Git blame tree entry budget exceeded") if count > @max_entries
            path = prefix.empty? ? name : "#{prefix}/#{name}"
            if entry.mode == "40000"
              stack << {entry.oid, path, depth + 1}
            else
              result[path] = entry
            end
          end
        end
        result
      end

      private def rename(parent : String, old_tree : String, current : Origin) : Origin?
        old = files(old_tree)
        newer = files(node(current.oid).tree)
        deleted = old.keys.reject { |path| newer.has_key?(path) }
        candidates = deleted.select { |path| same_kind?(old[path], current.entry) }
        candidates.sort_by!(&.to_slice)
        exact = candidates.select { |path| old[path].oid == current.entry.oid }
        chosen = exact.find { |path| File.basename(path) == File.basename(current.path) } || exact.first?
        if chosen
          return Origin.new(parent, chosen, old[chosen])
        end
        return nil if current.entry.mode == "120000"
        # diffcore-rename first accepts a unique basename at 75% similarity,
        # before the general best-score search. Uniqueness includes deleted
        # entries of other kinds, which cannot themselves become candidates.
        basename = File.basename(current.path)
        same_names = deleted.select { |path| File.basename(path) == basename }
        if same_names.size == 1 && same_kind?(old[same_names[0]], current.entry)
          @check.try &.call
          @work.tick
          path = same_names[0]
          if @similarity.score(old[path].oid, current.entry.oid) >= 45_000
            return Origin.new(parent, path, old[path])
          end
        end
        best_score = 29_999
        candidates.each do |path|
          @check.try &.call
          @work.tick
          score = @similarity.score(old[path].oid, current.entry.oid)
          next if score < 30_000
          basename = File.basename(path) == File.basename(current.path)
          if score > best_score || (score == best_score && basename &&
             chosen.try { |previous| File.basename(previous) != File.basename(current.path) })
            best_score = score
            chosen = path
          end
        end
        chosen.try { |path| Origin.new(parent, path, old[path]) }
      end
    end
  end
end
