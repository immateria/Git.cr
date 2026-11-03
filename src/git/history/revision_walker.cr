require "set"

module Git
  module History
    # One object a revision walk reached. path is the first path at which a
    # tree or blob was reached ("" for a root tree); commits and tags have
    # none.
    record ReachableObject, oid : String, type : String, path : String?

    # A commit as the revision walk sees it: its tree, its parents and its
    # committer time.
    record CommitNode, tree : String, parents : Array(String), time : Int64 do
      # Parse a commit body without assuming UTF-8: only the tree, the
      # parents and the committer time are read.
      def self.parse(raw : String, format : ObjectId::Format) : CommitNode
        tree = nil.as(String?)
        parents = [] of String
        time = 0_i64
        position = 0
        while position < raw.bytesize
          newline = raw.byte_index('\n'.ord, position) || raw.bytesize
          break if newline == position
          line = raw.byte_slice(position, newline - position)
          if line.starts_with?("tree ")
            tree = ObjectId.valid!(line.byte_slice(5), format)
          elsif line.starts_with?("parent ")
            parents << ObjectId.valid!(line.byte_slice(7), format)
          elsif line.starts_with?("committer ")
            close = line.rindex('>')
            if close
              fields = line.byte_slice(close + 1).split(' ', remove_empty: true)
              time = fields[0]?.try(&.to_i64?) || 0_i64
            end
          end
          position = newline + 1
        end
        CommitNode.new(tree || raise(Error.new("Git commit has no tree")), parents, time)
      end
    end

    # Git's revision walk (`rev-list`): commits reachable from wants and not
    # from haves, newest first by committer date with Git's SLOP for clock
    # skew; with objects, every tree, blob and tag they reach (`rev-list
    # --objects`), the object selection behind fetch serving, push and
    # connectivity checks; and ancestry questions.
    class RevisionWalker
      private UNINTERESTING = 1_u8
      private SEEN          = 2_u8
      private ADDED         = 4_u8

      # Commits whose dates go back further than this many queue entries
      # after every queued commit became uninteresting are not walked.
      private SLOP = 5

      getter repository : Repository

      @nodes = {} of String => CommitNode
      @flags = {} of String => UInt8

      def initialize(@repository : Repository, *,
                     @max_object_bytes : Int32 = 268_435_456,
                     @max_objects : Int64 = 50_000_000,
                     @check : Proc(Nil)? = nil)
        raise ArgumentError.new("invalid Git reachability budgets") if @max_object_bytes < 128 || @max_objects < 1
        # Shallow commits are walked as if they had no parents.
        @shallow = @repository.shallow_commits
      end

      def commit_node(oid : String) : CommitNode
        @nodes[oid]? || begin
          kind, raw = read(oid)
          raise Error.new("Git object #{oid} is not a commit") unless kind == "commit"
          node = CommitNode.parse(raw, @repository.object_format)
          node = node.copy_with(parents: [] of String) if @shallow.includes?(oid)
          @nodes[oid] = node
          node
        end
      end

      # Follow annotated tags to their final target: {tag OIDs, target, type}.
      def peel(oid : String) : {Array(String), String, String}
        tags = [] of String
        current = oid
        16.times do
          kind, raw = read(current)
          return {tags, current, kind} unless kind == "tag"
          tags << current
          target = nil.as(String?)
          raw.each_line do |line|
            break if line.empty?
            target = ObjectId.valid!(line.byte_slice(7), @repository.object_format) if line.starts_with?("object ")
          end
          current = target || raise Error.new("invalid Git annotated tag #{current}")
        end
        raise Error.new("Git annotated tag nesting limit exceeded")
      end

      # Commits reachable from wants and not from haves, newest first by
      # committer date (Git's default rev-list order).
      def commits(wants : Array(String), haves : Array(String)) : Array(String)
        queue = DateQueue.new
        wants.each do |oid|
          next unless add?(oid)
          queue.push(oid, commit_node(oid).time)
        end
        haves.each do |oid|
          mark(oid, UNINTERESTING)
          next unless add?(oid)
          queue.push(oid, commit_node(oid).time)
        end
        result = [] of String
        slop = SLOP
        until queue.empty?
          @check.try &.call
          oid = queue.pop
          node = commit_node(oid)
          uninteresting = flag?(oid, UNINTERESTING)
          if uninteresting
            mark_parents_uninteresting(oid)
          else
            result << oid
          end
          node.parents.each do |parent|
            next unless @repository.has_object?(parent) || !uninteresting
            next unless add?(parent)
            queue.push(parent, commit_node(parent).time)
          end
          if queue.all? { |queued| flag?(queued, UNINTERESTING) }
            slop -= 1
            break if slop <= 0
          else
            slop = SLOP
          end
        end
        result.reject { |oid| flag?(oid, UNINTERESTING) }
      end

      # Every object reachable from wants and not from haves. With
      # exclude_have_trees, the trees of the haves themselves are excluded
      # too, not only those of uninteresting parents of included commits
      # (Git's default); a sender uses it to skip what a receiver has.
      def objects(wants : Array(String), haves : Array(String) = [] of String, *,
                  exclude_have_trees : Bool = false) : Array(ReachableObject)
        items = [] of ReachableObject
        commit_wants = [] of String
        pending = [] of {String, String, String?}
        wants.each do |want|
          tags, target, kind = peel(want)
          tags.each { |tag| pending << {tag, "tag", nil} }
          case kind
          when "commit" then commit_wants << target
          when "tree"   then pending << {target, "tree", ""}
          else               pending << {target, kind, nil}
          end
        end
        commit_haves = [] of String
        haves.each do |have|
          next unless @repository.has_object?(have)
          _, target, kind = peel(have)
          case kind
          when "commit" then commit_haves << target
          when "tree"   then mark_tree_uninteresting(target)
          else               mark(target, UNINTERESTING)
          end
        end
        included = commits(commit_wants, commit_haves)
        included.each do |oid|
          commit_node(oid).parents.each do |parent|
            mark_tree_uninteresting(commit_node(parent).tree) if flag?(parent, UNINTERESTING) && @nodes.has_key?(parent)
          end
        end
        if exclude_have_trees
          commit_haves.each { |oid| mark_tree_uninteresting(commit_node(oid).tree) }
        end
        included.each do |oid|
          mark(oid, SEEN)
          items << ReachableObject.new(oid, "commit", nil)
          budget!(items)
        end
        pending.each do |oid, kind, path|
          if kind == "tree"
            walk_tree(oid, path || "", items)
          elsif !flag?(oid, UNINTERESTING) && !flag?(oid, SEEN)
            mark(oid, SEEN)
            items << ReachableObject.new(oid, kind, path)
          end
        end
        included.each { |oid| walk_tree(commit_node(oid).tree, "", items) }
        items
      end

      # Whether ancestor is reachable from descendant (or equal to it).
      # Git's paint_down_to_common: paint from both commits, newest first,
      # until only commits common to both remain queued. Flags are re-queued
      # when they change, so clock skew cannot cause a wrong answer.
      def ancestor?(ancestor : String, descendant : String, *, max_nodes : Int32 = 1_000_000) : Bool
        return true if ancestor == descendant
        left = 1_u8
        right = 2_u8
        stale = 4_u8
        paint = {ancestor => left, descendant => right}
        queue = DateQueue.new
        queue.push(ancestor, commit_node(ancestor).time)
        queue.push(descendant, commit_node(descendant).time)
        while queue.any? { |oid| (paint[oid] & stale) == 0 }
          @check.try &.call
          oid = queue.pop
          flags = paint[oid]
          if (flags & (left | right)) == (left | right)
            return true if oid == ancestor
            flags |= stale
          end
          commit_node(oid).parents.each do |parent|
            current = paint.fetch(parent, 0_u8)
            next if (current & flags) == flags
            next unless @repository.has_object?(parent)
            paint[parent] = current | flags
            raise Error.new("Git ancestry node budget exceeded") if paint.size > max_nodes
            queue.push(parent, commit_node(parent).time)
          end
        end
        false
      end

      private def walk_tree(root : String, root_path : String, items : Array(ReachableObject)) : Nil
        stack = [{root, "tree", root_path}]
        until stack.empty?
          @check.try &.call
          oid, kind, path = stack.pop
          next if flag?(oid, UNINTERESTING) || flag?(oid, SEEN)
          mark(oid, SEEN)
          items << ReachableObject.new(oid, kind, path)
          budget!(items)
          next unless kind == "tree"
          children = [] of {String, String, String}
          Tree.each_entry(read_tree(oid), @repository.object_format) do |mode, name, entry_oid|
            next if mode == "160000"
            child_path = path.empty? ? name : "#{path}/#{name}"
            children << {entry_oid, mode == "40000" ? "tree" : "blob", child_path}
          end
          children.reverse_each { |child| stack << child }
        end
      end

      private def mark_tree_uninteresting(root : String) : Nil
        stack = [root]
        until stack.empty?
          @check.try &.call
          oid = stack.pop
          next if flag?(oid, UNINTERESTING)
          mark(oid, UNINTERESTING)
          next unless @repository.has_object?(oid)
          Tree.each_entry(read_tree(oid), @repository.object_format) do |mode, _name, entry_oid|
            next if mode == "160000"
            if mode == "40000"
              stack << entry_oid
            else
              mark(entry_oid, UNINTERESTING)
            end
          end
        end
      end

      private def mark_parents_uninteresting(oid : String) : Nil
        stack = [oid]
        until stack.empty?
          current = stack.pop
          node = @nodes[current]? || next
          node.parents.each do |parent|
            next if flag?(parent, UNINTERESTING)
            mark(parent, UNINTERESTING)
            stack << parent if @nodes.has_key?(parent)
          end
        end
      end

      private def read_tree(oid : String) : String
        kind, raw = read(oid)
        raise Error.new("Git object #{oid} is not a tree") unless kind == "tree"
        raw
      end

      private def read(oid : String) : {String, String}
        @repository.object(oid, @max_object_bytes) { @check.try &.call }
      end

      private def add?(oid : String) : Bool
        return false if flag?(oid, ADDED)
        mark(oid, ADDED)
        true
      end

      private def flag?(oid : String, flag : UInt8) : Bool
        (@flags.fetch(oid, 0_u8) & flag) != 0
      end

      private def mark(oid : String, flag : UInt8) : Nil
        @flags[oid] = @flags.fetch(oid, 0_u8) | flag
      end

      private def budget!(items : Array(ReachableObject)) : Nil
        raise Error.new("Git reachable object budget exceeded") if items.size > @max_objects
      end
    end

    # A max-heap of commits by committer time; ties pop in insertion order.
    class DateQueue
      @heap = [] of {Int64, Int64, String}
      @counter = 0_i64

      def push(oid : String, time : Int64) : Nil
        @counter += 1
        @heap << {time, -@counter, oid}
        index = @heap.size - 1
        while index > 0
          parent = (index - 1) // 2
          break if (@heap[parent] <=> @heap[index]) >= 0
          @heap.swap(parent, index)
          index = parent
        end
      end

      def pop : String
        top = @heap[0]
        last = @heap.pop
        unless @heap.empty?
          @heap[0] = last
          index = 0
          loop do
            left = index * 2 + 1
            right = left + 1
            largest = index
            largest = left if left < @heap.size && (@heap[left] <=> @heap[largest]) > 0
            largest = right if right < @heap.size && (@heap[right] <=> @heap[largest]) > 0
            break if largest == index
            @heap.swap(index, largest)
            index = largest
          end
        end
        top[2]
      end

      def empty? : Bool
        @heap.empty?
      end

      def max_time : Int64
        @heap[0][0]
      end

      def all?(& : String -> Bool) : Bool
        @heap.all? { |entry| yield entry[2] }
      end

      def any?(& : String -> Bool) : Bool
        @heap.any? { |entry| yield entry[2] }
      end
    end
  end

  class Repository
    # `git rev-list --objects <wants> --not <haves>` as typed items.
    def reachable_objects(wants : Array(String), haves : Array(String) = [] of String, *,
                          exclude_have_trees : Bool = false,
                          max_objects : Int64 = 50_000_000,
                          max_object_bytes : Int32 = 268_435_456,
                          check : Proc(Nil)? = nil) : Array(History::ReachableObject)
      History::RevisionWalker.new(self, max_object_bytes: max_object_bytes,
        max_objects: max_objects, check: check).objects(wants, haves,
        exclude_have_trees: exclude_have_trees)
    end

    # Whether ancestor is reachable from descendant (`merge-base --is-ancestor`).
    def ancestor?(ancestor : String, descendant : String, *, max_nodes : Int32 = 1_000_000,
                  check : Proc(Nil)? = nil) : Bool
      History::RevisionWalker.new(self, check: check).ancestor?(ancestor, descendant, max_nodes: max_nodes)
    end
  end
end
