module Git
  # :nodoc:
  # The line diff behind Patch: a port of the algorithm in Git's xdiff
  # (xdl_cleanup_records, Myers' linear-space middle snake with its
  # heuristics, xdl_change_compact with the indent heuristic, and the
  # unified hunk emitter), so hunks come out as Git draws them. Lines are
  # compared as raw bytes.
  module TextDiff
    # One side of a comparison: its lines, their class IDs, which lines
    # changed, and the reduced view the Myers search runs on.
    class Side
      getter lines : Array(Bytes)
      getter ids : Array(Int32)
      property reduced_index : Array(Int32) = [] of Int32
      property reduced_ids : Array(Int32) = [] of Int32
      property first : Int32 = 0
      property last : Int32 = -1

      def initialize(@lines : Array(Bytes), @ids : Array(Int32))
        @changed = Array(Bool).new(@lines.size + 2, false)
      end

      def size : Int32
        @lines.size
      end

      def changed?(index : Int32) : Bool
        @changed[index + 1]
      end

      def mark(index : Int32, value : Bool = true) : Nil
        @changed[index + 1] = value
      end
    end

    # A run of consecutive changed lines in the side being compacted.
    class Group
      property lo : Int32 = 0
      property hi : Int32 = 0
    end

    SNAKE_COUNT     =   20
    HEURISTIC_COST  =  256
    MIN_MAX_COST    =  256
    K_HEURISTIC     =    4
    MAX_EQUAL_LIMIT = 1024
    SIM_SCAN_WINDOW =  100
    KPDIS_RUN       =    4

    # Render the hunks that turn old_data into new_data (the body of
    # `git diff`'s patch, without file headers), or "" when they are
    # equal. max_lines bounds the lines of both sides together.
    def self.hunks(old_data : Bytes, new_data : Bytes, context : Int32 = 3, *,
                   indent_heuristic : Bool = true, max_lines : Int32 = 1_000_000,
                   check : Proc(Nil)? = nil) : String
      raise ArgumentError.new("diff context must not be negative") if context < 0
      return "" if old_data == new_data
      old_lines = split_lines(old_data)
      new_lines = split_lines(new_data)
      raise Error.new("Git text diff line budget exceeded") if old_lines.size.to_i64 + new_lines.size > max_lines
      classes = {} of Bytes => Int32
      count_old = [] of Int32
      count_new = [] of Int32
      old_ids = classify(old_lines, classes, count_old, count_new, true)
      new_ids = classify(new_lines, classes, count_old, count_new, false)
      old_side = Side.new(old_lines, old_ids)
      new_side = Side.new(new_lines, new_ids)
      trim_ends(old_side, new_side)
      cleanup_records(old_side, new_side, count_old, count_new)
      search(old_side, new_side, check)
      compact(old_side, new_side, indent_heuristic, check)
      compact(new_side, old_side, indent_heuristic, check)
      emit(old_side, new_side, build_script(old_side, new_side), context)
    end

    # Whether Git would treat this content as binary: a NUL byte in the
    # first 8000 bytes.
    def self.binary?(data : Bytes) : Bool
      limit = {data.size, 8000}.min
      limit.times { |i| return true if data[i] == 0_u8 }
      false
    end

    private def self.split_lines(data : Bytes) : Array(Bytes)
      lines = [] of Bytes
      start = 0
      data.size.times do |i|
        next unless data[i] == 10_u8
        lines << data[start, i + 1 - start]
        start = i + 1
      end
      lines << data[start, data.size - start] if start < data.size
      lines
    end

    private def self.classify(lines : Array(Bytes), classes : Hash(Bytes, Int32),
                              count_old : Array(Int32), count_new : Array(Int32), old : Bool) : Array(Int32)
      lines.map do |line|
        id = classes[line]? || begin
          fresh = classes.size
          classes[line] = fresh
          count_old << 0
          count_new << 0
          fresh
        end
        (old ? count_old : count_new)[id] += 1
        id
      end
    end

    private def self.trim_ends(a : Side, b : Side) : Nil
      limit = {a.size, b.size}.min
      prefix = 0
      while prefix < limit && a.ids[prefix] == b.ids[prefix]
        prefix += 1
      end
      a.first = b.first = prefix
      remaining = limit - prefix
      suffix = 0
      while suffix < remaining && a.ids[a.size - 1 - suffix] == b.ids[b.size - 1 - suffix]
        suffix += 1
      end
      a.last = a.size - suffix - 1
      b.last = b.size - suffix - 1
    end

    private def self.bogo_sqrt(n : Int32) : Int32
      result = 1
      while n > 0
        n >>= 2
        result <<= 1
      end
      result
    end

    # Drop lines with no counterpart (they are plainly changed) and
    # multi-match lines sitting among such runs, leaving the reduced
    # sequences the Myers search compares.
    private def self.cleanup_records(a : Side, b : Side, count_old : Array(Int32), count_new : Array(Int32)) : Nil
      dis_a = discard_levels(a, count_new)
      dis_b = discard_levels(b, count_old)
      reduce(a, dis_a)
      reduce(b, dis_b)
    end

    private def self.discard_levels(side : Side, other_counts : Array(Int32)) : Array(UInt8)
      dis = Array(UInt8).new(side.size + 1, 0_u8)
      limit = {bogo_sqrt(side.size), MAX_EQUAL_LIMIT}.min
      (side.first..side.last).each do |i|
        matches = other_counts[side.ids[i]]
        dis[i] = matches == 0 ? 0_u8 : (matches >= limit ? 2_u8 : 1_u8)
      end
      dis
    end

    private def self.reduce(side : Side, dis : Array(UInt8)) : Nil
      index = [] of Int32
      ids = [] of Int32
      (side.first..side.last).each do |i|
        if dis[i] == 1 || (dis[i] == 2 && !multi_match_run?(dis, i, side.first, side.last))
          index << i
          ids << side.ids[i]
        else
          side.mark(i)
        end
      end
      side.reduced_index = index
      side.reduced_ids = ids
    end

    private def self.multi_match_run?(dis : Array(UInt8), i : Int32, first : Int32, last : Int32) : Bool
      first = i - SIM_SCAN_WINDOW if i - first > SIM_SCAN_WINDOW
      last = i + SIM_SCAN_WINDOW if last - i > SIM_SCAN_WINDOW
      r = 1
      none_before = 0
      multi_before = 1
      while i - r >= first
        if dis[i - r] == 0
          none_before += 1
        elsif dis[i - r] == 2
          multi_before += 1
        else
          break
        end
        r += 1
      end
      return false if none_before == 0
      r = 1
      none_after = 0
      multi_after = 1
      while i + r <= last
        if dis[i + r] == 0
          none_after += 1
        elsif dis[i + r] == 2
          multi_after += 1
        else
          break
        end
        r += 1
      end
      return false if none_after == 0
      none_after += none_before
      multi_after += multi_before
      multi_after * KPDIS_RUN < multi_after + none_after
    end

    # Myers' search over the reduced sequences, by divide and conquer on
    # the middle snake; marks the changed lines of both sides.
    private def self.search(a : Side, b : Side, check : Proc(Nil)?) : Nil
      ha1 = a.reduced_ids
      ha2 = b.reduced_ids
      diagonals = ha1.size + ha2.size + 3
      kvdf = Array(Int32).new(diagonals, 0)
      kvdb = Array(Int32).new(diagonals, 0)
      base = ha2.size + 1
      max_cost = {bogo_sqrt(diagonals), MIN_MAX_COST}.max
      pending = [{0, ha1.size, 0, ha2.size, false}]
      until pending.empty?
        check.try &.call
        off1, lim1, off2, lim2, need_min = pending.pop
        while off1 < lim1 && off2 < lim2 && ha1[off1] == ha2[off2]
          off1 += 1
          off2 += 1
        end
        while off1 < lim1 && off2 < lim2 && ha1[lim1 - 1] == ha2[lim2 - 1]
          lim1 -= 1
          lim2 -= 1
        end
        if off1 == lim1
          while off2 < lim2
            b.mark(b.reduced_index[off2])
            off2 += 1
          end
        elsif off2 == lim2
          while off1 < lim1
            a.mark(a.reduced_index[off1])
            off1 += 1
          end
        else
          i1, i2, min_lo, min_hi = split(ha1, off1, lim1, ha2, off2, lim2, kvdf, kvdb, base, need_min, max_cost)
          pending << {off1, i1, off2, i2, min_lo}
          pending << {i1, lim1, i2, lim2, min_hi}
        end
      end
    end

    private def self.split(ha1 : Array(Int32), off1 : Int32, lim1 : Int32, ha2 : Array(Int32), off2 : Int32, lim2 : Int32,
                           kvdf : Array(Int32), kvdb : Array(Int32), base : Int32, need_min : Bool,
                           max_cost : Int32) : {Int32, Int32, Bool, Bool}
      dmin = off1 - lim2
      dmax = lim1 - off2
      fmid = off1 - off2
      bmid = lim1 - lim2
      odd = ((fmid - bmid) & 1) == 1
      fmin = fmax = fmid
      bmin = bmax = bmid
      kvdf[base + fmid] = off1
      kvdb[base + bmid] = lim1
      ec = 1
      loop do
        got_snake = false
        if fmin > dmin
          fmin -= 1
          kvdf[base + fmin - 1] = -1
        else
          fmin += 1
        end
        if fmax < dmax
          fmax += 1
          kvdf[base + fmax + 1] = -1
        else
          fmax -= 1
        end
        d = fmax
        while d >= fmin
          i1 = kvdf[base + d - 1] >= kvdf[base + d + 1] ? kvdf[base + d - 1] + 1 : kvdf[base + d + 1]
          prev1 = i1
          i2 = i1 - d
          while i1 < lim1 && i2 < lim2 && ha1[i1] == ha2[i2]
            i1 += 1
            i2 += 1
          end
          got_snake = true if i1 - prev1 > SNAKE_COUNT
          kvdf[base + d] = i1
          return {i1, i2, true, true} if odd && bmin <= d && d <= bmax && kvdb[base + d] <= i1
          d -= 2
        end

        if bmin > dmin
          bmin -= 1
          kvdb[base + bmin - 1] = Int32::MAX
        else
          bmin += 1
        end
        if bmax < dmax
          bmax += 1
          kvdb[base + bmax + 1] = Int32::MAX
        else
          bmax -= 1
        end
        d = bmax
        while d >= bmin
          i1 = kvdb[base + d - 1] < kvdb[base + d + 1] ? kvdb[base + d - 1] : kvdb[base + d + 1] - 1
          prev1 = i1
          i2 = i1 - d
          while i1 > off1 && i2 > off2 && ha1[i1 - 1] == ha2[i2 - 1]
            i1 -= 1
            i2 -= 1
          end
          got_snake = true if prev1 - i1 > SNAKE_COUNT
          kvdb[base + d] = i1
          return {i1, i2, true, true} if !odd && fmin <= d && d <= fmax && i1 <= kvdf[base + d]
          d -= 2
        end

        unless need_min
          if got_snake && ec > HEURISTIC_COST
            best = 0
            best_i1 = best_i2 = 0
            d = fmax
            while d >= fmin
              dd = d > fmid ? d - fmid : fmid - d
              i1 = kvdf[base + d]
              i2 = i1 - d
              v = (i1 - off1) + (i2 - off2) - dd
              if v > K_HEURISTIC * ec && v > best && off1 + SNAKE_COUNT <= i1 && i1 < lim1 &&
                 off2 + SNAKE_COUNT <= i2 && i2 < lim2
                k = 1
                while ha1[i1 - k] == ha2[i2 - k]
                  if k == SNAKE_COUNT
                    best = v
                    best_i1 = i1
                    best_i2 = i2
                    break
                  end
                  k += 1
                end
              end
              d -= 2
            end
            return {best_i1, best_i2, true, false} if best > 0

            best = 0
            d = bmax
            while d >= bmin
              dd = d > bmid ? d - bmid : bmid - d
              i1 = kvdb[base + d]
              i2 = i1 - d
              v = (lim1 - i1) + (lim2 - i2) - dd
              if v > K_HEURISTIC * ec && v > best && off1 < i1 && i1 <= lim1 - SNAKE_COUNT &&
                 off2 < i2 && i2 <= lim2 - SNAKE_COUNT
                k = 0
                while ha1[i1 + k] == ha2[i2 + k]
                  if k == SNAKE_COUNT - 1
                    best = v
                    best_i1 = i1
                    best_i2 = i2
                    break
                  end
                  k += 1
                end
              end
              d -= 2
            end
            return {best_i1, best_i2, false, true} if best > 0
          end

          if ec >= max_cost
            fbest = fbest1 = -1
            d = fmax
            while d >= fmin
              i1 = {kvdf[base + d], lim1}.min
              i2 = i1 - d
              if lim2 < i2
                i1 = lim2 + d
                i2 = lim2
              end
              if fbest < i1 + i2
                fbest = i1 + i2
                fbest1 = i1
              end
              d -= 2
            end
            bbest = bbest1 = Int32::MAX
            d = bmax
            while d >= bmin
              i1 = {off1, kvdb[base + d]}.max
              i2 = i1 - d
              if i2 < off2
                i1 = off2 + d
                i2 = off2
              end
              if i1 + i2 < bbest
                bbest = i1 + i2
                bbest1 = i1
              end
              d -= 2
            end
            if (lim1 + lim2) - bbest < fbest - (off1 + off2)
              return {fbest1, fbest - fbest1, true, false}
            else
              return {bbest1, bbest - bbest1, false, true}
            end
          end
        end
        ec += 1
      end
    end

    # Slide each group of changed lines to where Git would put it: merged
    # with neighbours, aligned with the other side's changes, or (with
    # the indent heuristic) at the most readable split.
    private def self.compact(side : Side, other : Side, indent_heuristic : Bool, check : Proc(Nil)?) : Nil
      g = Group.new
      go = Group.new
      while side.changed?(g.hi)
        g.hi += 1
      end
      while other.changed?(go.hi)
        go.hi += 1
      end
      loop do
        check.try &.call
        if g.hi != g.lo
          earliest_end = 0
          end_matching_other = -1
          groupsize = 0
          loop do
            groupsize = g.hi - g.lo
            end_matching_other = -1
            while slide_up(side, g)
              raise Error.new("Git diff group sync broken sliding up") unless previous_group(other, go)
            end
            earliest_end = g.hi
            end_matching_other = g.hi if go.hi > go.lo
            while slide_down(side, g)
              raise Error.new("Git diff group sync broken sliding down") unless next_group(other, go)
              end_matching_other = g.hi if go.hi > go.lo
            end
            break if groupsize == g.hi - g.lo
          end
          if g.hi == earliest_end
            # No shifting was possible.
          elsif end_matching_other != -1
            while go.hi == go.lo
              raise Error.new("Git diff match disappeared") unless slide_up(side, g)
              raise Error.new("Git diff group sync broken sliding to match") unless previous_group(other, go)
            end
          elsif indent_heuristic
            best_shift = best_split(side, g, groupsize, earliest_end)
            while g.hi > best_shift
              raise Error.new("Git diff best shift unreached") unless slide_up(side, g)
              raise Error.new("Git diff group sync broken sliding to blank line") unless previous_group(other, go)
            end
          end
        end
        break unless next_group(side, g)
        raise Error.new("Git diff group sync broken moving to next group") unless next_group(other, go)
      end
    end

    private def self.next_group(side : Side, g : Group) : Bool
      return false if g.hi == side.size
      g.lo = g.hi + 1
      g.hi = g.lo
      while side.changed?(g.hi)
        g.hi += 1
      end
      true
    end

    private def self.previous_group(side : Side, g : Group) : Bool
      return false if g.lo == 0
      g.hi = g.lo - 1
      g.lo = g.hi
      while side.changed?(g.lo - 1)
        g.lo -= 1
      end
      true
    end

    private def self.slide_down(side : Side, g : Group) : Bool
      return false unless g.hi < side.size && side.ids[g.lo] == side.ids[g.hi]
      side.mark(g.lo, false)
      g.lo += 1
      side.mark(g.hi)
      g.hi += 1
      while side.changed?(g.hi)
        g.hi += 1
      end
      true
    end

    private def self.slide_up(side : Side, g : Group) : Bool
      return false unless g.lo > 0 && side.ids[g.lo - 1] == side.ids[g.hi - 1]
      g.lo -= 1
      side.mark(g.lo)
      g.hi -= 1
      side.mark(g.hi, false)
      while side.changed?(g.lo - 1)
        g.lo -= 1
      end
      true
    end

    MAX_INDENT                          = 200
    MAX_BLANKS                          =  20
    START_OF_FILE_PENALTY               =   1
    END_OF_FILE_PENALTY                 =  21
    TOTAL_BLANK_WEIGHT                  = -30
    POST_BLANK_WEIGHT                   =   6
    RELATIVE_INDENT_PENALTY             =  -4
    RELATIVE_INDENT_WITH_BLANK_PENALTY  =  10
    RELATIVE_OUTDENT_PENALTY            =  24
    RELATIVE_OUTDENT_WITH_BLANK_PENALTY =  17
    RELATIVE_DEDENT_PENALTY             =  23
    RELATIVE_DEDENT_WITH_BLANK_PENALTY  =  17
    INDENT_WEIGHT                       =  60
    INDENT_HEURISTIC_MAX_SLIDING        = 100

    # The shift (an end position) of a slidable group with the best split
    # score under Git's indent heuristic.
    private def self.best_split(side : Side, g : Group, groupsize : Int32, earliest_end : Int32) : Int32
      shift = earliest_end
      shift = g.hi - groupsize - 1 if g.hi - groupsize - 1 > shift
      shift = g.hi - INDENT_HEURISTIC_MAX_SLIDING if g.hi - INDENT_HEURISTIC_MAX_SLIDING > shift
      best_shift = -1
      best_indent = 0
      best_penalty = 0
      while shift <= g.hi
        indent = 0
        penalty = 0
        indent, penalty = add_split(measure_split(side, shift), indent, penalty)
        indent, penalty = add_split(measure_split(side, shift - groupsize), indent, penalty)
        compared = (indent <=> best_indent)
        if best_shift == -1 || INDENT_WEIGHT * compared + (penalty - best_penalty) <= 0
          best_indent = indent
          best_penalty = penalty
          best_shift = shift
        end
        shift += 1
      end
      best_shift
    end

    private record Measurement, end_of_file : Bool, indent : Int32, pre_blank : Int32, pre_indent : Int32,
      post_blank : Int32, post_indent : Int32

    private def self.line_indent(line : Bytes) : Int32
      indent = 0
      line.each do |byte|
        case byte
        when 32
          indent += 1
        when 9
          indent += 8 - indent % 8
        when 10, 11, 12, 13
          # Other whitespace is ignored.
        else
          return indent
        end
        return MAX_INDENT if indent >= MAX_INDENT
      end
      -1
    end

    private def self.measure_split(side : Side, split : Int32) : Measurement
      if split >= side.size
        end_of_file = true
        indent = -1
      else
        end_of_file = false
        indent = line_indent(side.lines[split])
      end
      pre_blank = 0
      pre_indent = -1
      i = split - 1
      while i >= 0
        pre_indent = line_indent(side.lines[i])
        break if pre_indent != -1
        pre_blank += 1
        if pre_blank == MAX_BLANKS
          pre_indent = 0
          break
        end
        i -= 1
      end
      post_blank = 0
      post_indent = -1
      i = split + 1
      while i < side.size
        post_indent = line_indent(side.lines[i])
        break if post_indent != -1
        post_blank += 1
        if post_blank == MAX_BLANKS
          post_indent = 0
          break
        end
        i += 1
      end
      Measurement.new(end_of_file, indent, pre_blank, pre_indent, post_blank, post_indent)
    end

    private def self.add_split(m : Measurement, effective_indent : Int32, penalty : Int32) : {Int32, Int32}
      penalty += START_OF_FILE_PENALTY if m.pre_indent == -1 && m.pre_blank == 0
      penalty += END_OF_FILE_PENALTY if m.end_of_file
      post_blank = m.indent == -1 ? 1 + m.post_blank : 0
      total_blank = m.pre_blank + post_blank
      penalty += TOTAL_BLANK_WEIGHT * total_blank
      penalty += POST_BLANK_WEIGHT * post_blank
      indent = m.indent != -1 ? m.indent : m.post_indent
      any_blanks = total_blank != 0
      effective_indent += indent
      if indent == -1 || m.pre_indent == -1 || indent == m.pre_indent
        # No additional adjustments needed.
      elsif indent > m.pre_indent
        penalty += any_blanks ? RELATIVE_INDENT_WITH_BLANK_PENALTY : RELATIVE_INDENT_PENALTY
      elsif m.post_indent != -1 && m.post_indent > indent
        penalty += any_blanks ? RELATIVE_OUTDENT_WITH_BLANK_PENALTY : RELATIVE_OUTDENT_PENALTY
      else
        penalty += any_blanks ? RELATIVE_DEDENT_WITH_BLANK_PENALTY : RELATIVE_DEDENT_PENALTY
      end
      {effective_indent, penalty}
    end

    # The changed ranges, in order, as (old line, old count, new line,
    # new count) with zero-based lines.
    private def self.build_script(a : Side, b : Side) : Array({Int32, Int32, Int32, Int32})
      script = [] of {Int32, Int32, Int32, Int32}
      i1 = 0
      i2 = 0
      while i1 < a.size || i2 < b.size
        if a.changed?(i1) || b.changed?(i2)
          j1 = i1
          j2 = i2
          while a.changed?(j1)
            j1 += 1
          end
          while b.changed?(j2)
            j2 += 1
          end
          script << {i1, j1 - i1, i2, j2 - i2}
          i1 = j1
          i2 = j2
        else
          i1 += 1
          i2 += 1
        end
      end
      script
    end

    private def self.emit(a : Side, b : Side, script : Array({Int32, Int32, Int32, Int32}), context : Int32) : String
      funcname = nil.as(Bytes?)
      func_scanned = -1
      String.build do |io|
        index = 0
        while index < script.size
          last = index
          while last + 1 < script.size
            previous = script[last]
            following = script[last + 1]
            break if following[0] - (previous[0] + previous[1]) > 2 * context
            last += 1
          end
          first_change = script[index]
          last_change = script[last]
          s1 = {first_change[0] - context, 0}.max
          s2 = {first_change[2] - context, 0}.max
          e1 = {last_change[0] + last_change[1] + context, a.size}.min
          e2 = {last_change[2] + last_change[3] + context, b.size}.min

          line = s1 - 1
          while line > func_scanned && line >= 0
            if found = function_name(a.lines[line])
              funcname = found
              break
            end
            line -= 1
          end
          func_scanned = s1 - 1

          io << "@@ -" << hunk_range(s1, e1 - s1) << " +" << hunk_range(s2, e2 - s2) << " @@"
          if name = funcname
            io << ' '
            io.write(name)
          end
          io << '\n'

          position = s2
          (index..last).each do |c|
            old_at, old_count, new_at, new_count = script[c]
            while position < new_at
              emit_line(io, ' ', b.lines[position])
              position += 1
            end
            old_count.times { |k| emit_line(io, '-', a.lines[old_at + k]) }
            new_count.times { |k| emit_line(io, '+', b.lines[new_at + k]) }
            position = new_at + new_count
          end
          while position < e2
            emit_line(io, ' ', b.lines[position])
            position += 1
          end
          index = last + 1
        end
      end
    end

    private def self.hunk_range(start : Int32, count : Int32) : String
      first = count == 0 ? start : start + 1
      count == 1 ? first.to_s : "#{first},#{count}"
    end

    private def self.emit_line(io : IO, prefix : Char, line : Bytes) : Nil
      io << prefix
      io.write(line)
      io << "\n\\ No newline at end of file\n" unless line.last? == 10_u8
    end

    # Git's default funcname rule: a line starting with a letter, "_" or
    # "$", cut to 80 bytes and stripped of trailing whitespace.
    private def self.function_name(line : Bytes) : Bytes?
      first = line[0]?
      return nil unless first && (first.chr.ascii_letter? || first == 95_u8 || first == 36_u8)
      size = {line.size, 80}.min
      while size > 0 && {32_u8, 9_u8, 10_u8, 11_u8, 12_u8, 13_u8}.includes?(line[size - 1])
        size -= 1
      end
      line[0, size]
    end
  end
end
