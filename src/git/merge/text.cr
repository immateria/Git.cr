module Git
  struct Merge
    # :nodoc:
    # One edit against the base's half-open line interval. Replacement lines
    # are byte-exact; no newline conversion or Git attribute filtering.
    record LineEdit, start : Int32, stop : Int32, replacement : Array(String)

    module Text
      MAX_LINES =     700
      MAX_CELLS = 250_000

      # A conservative bounded diff3. Distinct, non-touching base-relative
      # line edits can be combined. Adjacent non-empty edits (even when their
      # half-open ranges only touch), boundary insertions, overlap, binary
      # content and high-complexity inputs return nil (conflict).
      def self.merge(base : String, ours : String, theirs : String) : String?
        return nil unless {base, ours, theirs}.all? { |s| s.valid_encoding? && !s.includes?('\0') }
        a = base.lines(chomp: false)
        b = ours.lines(chomp: false)
        c = theirs.lines(chomp: false)
        return nil unless {a, b, c}.all? { |lines| lines.size <= MAX_LINES }
        return nil if a.size.to_i64 * {b.size, c.size}.max > MAX_CELLS
        ours_edits = edits(a, b)
        theirs_edits = edits(a, c)
        # Identical edits can be collapsed. Non-identical overlapping or
        # abutting edits must conflict; otherwise nearby changes could be
        # silently combined where Git would stop for resolution.
        all = ours_edits.map { |change| {change, 0} } +
              theirs_edits.map { |change| {change, 1} }
        all.sort_by! { |change, side| {change.start, change.stop, side} }
        combined = [] of LineEdit
        all.each do |edit, side|
          previous = combined.last?
          if previous && collides?(previous, edit)
            return nil unless previous == edit
            next
          end
          combined << edit
        end
        result = [] of String
        offset = 0
        combined.each do |edit|
          result.concat(a[offset...edit.start])
          result.concat(edit.replacement)
          offset = edit.stop
        end
        result.concat(a[offset..])
        result.join
      end

      # No full patch strings, only edit spans and their replacements.
      private def self.edits(base : Array(String), side : Array(String)) : Array(LineEdit)
        n = base.size
        m = side.size
        matrix = Array(Array(Int32)).new(n + 1) { Array(Int32).new(m + 1, 0) }
        (0...n).reverse_each do |i|
          (0...m).reverse_each do |j|
            matrix[i][j] = base[i] == side[j] ? matrix[i + 1][j + 1] + 1 : {matrix[i + 1][j], matrix[i][j + 1]}.max
          end
        end
        changes = [] of LineEdit
        i = 0
        j = 0
        start = -1
        replacement = [] of String
        while i < n || j < m
          if i < n && j < m && base[i] == side[j]
            if start >= 0
              changes << LineEdit.new(start, i, replacement)
              start = -1
              replacement = [] of String
            end
            i += 1
            j += 1
          elsif i < n && (j == m || matrix[i + 1][j] >= matrix[i][j + 1])
            start = i if start < 0
            i += 1
          else
            start = i if start < 0
            replacement << side[j]
            j += 1
          end
        end
        changes << LineEdit.new(start, i, replacement) if start >= 0
        changes
      end

      private def self.collides?(a : LineEdit, b : LineEdit) : Bool
        return false if a.stop < b.start
        true
      end
    end

    # A new merged regular blob may be written before ref/index publication;
    # an interruption can leave an unreachable immutable object. No model
    # tool is authorized merely by producing this object.
    protected def self.merge_blob(repository : Repository, base : Checkout::FileState?,
                                  ours : Checkout::FileState?, theirs : Checkout::FileState?,
                                  max_bytes : Int32, check : Proc(Nil)?) : {Checkout::FileState, String}?
      return nil unless base && ours && theirs && {base.mode, ours.mode, theirs.mode}.all? { |mode| {"100644", "100755"}.includes?(mode) }
      mode = if ours.mode == theirs.mode || theirs.mode == base.mode
               ours.mode
             elsif ours.mode == base.mode
               theirs.mode
             else
               return nil
             end
      base_kind, original = repository.object(base.oid, max_bytes) { check.try &.call }
      ours_kind, left = repository.object(ours.oid, max_bytes) { check.try &.call }
      theirs_kind, right = repository.object(theirs.oid, max_bytes) { check.try &.call }
      return nil unless base_kind == "blob" && ours_kind == "blob" && theirs_kind == "blob"
      merged = if ours.oid == theirs.oid || theirs.oid == base.oid
                 left
               elsif ours.oid == base.oid
                 right
               else
                 Text.merge(original, left, right)
               end
      return nil unless merged
      oid = repository.write_blob(merged, max_bytes: max_bytes, check: check)
      {Checkout::FileState.new(mode, oid), merged}
    end
  end
end
