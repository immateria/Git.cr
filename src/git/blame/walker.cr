module Git
  struct Blame
    # A contiguous run of final lines whose current origin lines are also
    # contiguous. Passing spans avoids per-line walks through long histories.
    private record Span, final_start : Int32, source_start : Int32, count : Int32

    private class Walker
      @pending = {} of {String, String} => {Origin, Array(Span)}
      @stack = [] of {String, String}
      @states = Set({String, String}).new
      @contents : Array(String)
      @result : Array(Line?)

      def initialize(@history : History, @revision : String, @path : String,
                     @first_parent : Bool, @follow_renames : Bool,
                     @max_history_nodes : Int32, @work : TextDiff::Work,
                     @check : Proc(Nil)?)
        entry = @history.lookup(@history.node(@revision).tree, @path) ||
                raise Error.new("Git blame path not present in revision")
        raise Error.new("Git blame path is not a file") unless @history.regular_or_symlink?(entry)
        @contents = @history.lines(entry)
        @result = Array(Line?).new(@contents.size, nil)
        unless @contents.empty?
          schedule(Origin.new(@revision, @path, entry), [Span.new(0, 0, @contents.size)])
        end
      end

      def run : Blame
        until @stack.empty?
          @check.try &.call
          key = @stack.pop
          unless @states.includes?(key)
            raise Error.new("Git blame history-state budget exceeded") if @states.size >= @max_history_nodes
            @states.add(key)
          end
          @work.tick
          origin, spans = @pending.delete(key).not_nil!
          process(origin, spans)
        end
        lines = @result.map { |line| line || raise Error.new("Git blame attribution incomplete") }
        Blame.new(@revision, @path, lines, @history.scanned)
      end

      private def schedule(origin : Origin, spans : Array(Span)) : Nil
        return if spans.empty?
        key = {origin.oid, origin.path}
        if pending = @pending[key]?
          pending[1].concat(spans)
        else
          @pending[key] = {origin, spans}
          @stack << key
        end
      end

      private def process(origin : Origin, spans : Array(Span)) : Nil
        node = @history.node(origin.oid)
        parents = @first_parent ? node.parents.first(1) : node.parents
        origins = Array(Origin?).new(parents.size, nil)
        # Git checks every same-path parent before considering renames. A
        # direct whole-blob match therefore wins over a renamed parent, even
        # when that renamed parent occurs earlier in the commit header.
        2.times do |pass|
          break if pass == 1 && !@follow_renames
          parents.each_with_index do |parent, index|
            next if origins[index]
            @work.tick
            older = @history.parent_origin(parent, origin, pass == 1)
            next unless older
            if older.entry.oid == origin.entry.oid
              schedule(older, spans)
              return
            end
            origins[index] = older
          end
        end
        remaining = spans
        origins.each do |older|
          break if remaining.empty?
          next unless older
          @history.lines(older.entry)
          matched = TextDiff.equal_spans(@history.blob(older.entry.oid).to_slice,
            @history.blob(origin.entry.oid).to_slice, max_lines: @history.max_lines,
            work: @work, check: @check)
          passed, remaining = partition(remaining, matched)
          schedule(older, passed)
        end
        remaining.each do |span|
          span.count.times do |offset|
            @check.try &.call if offset % 1024 == 0
            final = span.final_start + offset
            raise Error.new("Git blame duplicate attribution") if @result[final]
            @result[final] = Line.new(origin.oid, origin.path, span.source_start + offset + 1,
              final + 1, @contents[final], node.author, node.committer, node.parents.empty?)
          end
        end
      end

      private def partition(spans : Array(Span), matched : Array({Int32, Int32, Int32})) : {Array(Span), Array(Span)}
        passed = [] of Span
        remaining = [] of Span
        spans.each do |span|
          @work.tick
          cursor = span.source_start
          finish = cursor + span.count
          low = 0
          high = matched.size
          while low < high
            @work.tick
            mid = low + (high - low) // 2
            _, start, count = matched[mid]
            if start + count <= cursor
              low = mid + 1
            else
              high = mid
            end
          end
          index = low
          while index < matched.size
            @work.tick
            old_start, start, count = matched[index]
            break if start >= finish
            left = {cursor, start}.max
            right = {finish, start + count}.min
            if left < right
              remaining << Span.new(span.final_start + cursor - span.source_start, cursor, left - cursor) if cursor < left
              passed << Span.new(span.final_start + left - span.source_start, old_start + left - start, right - left)
              cursor = right
            end
            index += 1
          end
          remaining << Span.new(span.final_start + cursor - span.source_start, cursor, finish - cursor) if cursor < finish
        end
        {passed, remaining}
      end
    end
  end
end
