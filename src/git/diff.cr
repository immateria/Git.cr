module Git
  # A deterministic, bounded LCS diff. We deliberately cap quadratic memory
  # instead of claiming a general-purpose Git/Myers implementation.
  module TextDiff
    MAX_LINES =     700
    MAX_CELLS = 250_000

    # A patch is a textual presentation of an arbitrary byte-exact Git path.
    # Quote before interpolation so tabs, newlines, quotes and non-UTF8 bytes
    # cannot produce ambiguous or forged patch headers.
    def self.validate_path!(path : String) : Nil
      PathBytes.validate_relative!(path)
    rescue ex : Error
      raise ArgumentError.new("invalid Git diff path: #{ex.message}")
    end

    def self.unified(old_text : String, new_text : String, path : String, old_mode : String?, new_mode : String?, context : Int32 = 3) : String
      validate_path!(path)
      raise Error.new("unsupported Git binary content in text diff") unless old_text.valid_encoding? && new_text.valid_encoding? && !old_text.includes?('\0') && !new_text.includes?('\0')
      old_lines = old_text.lines(chomp: false)
      new_lines = new_text.lines(chomp: false)
      raise Error.new("Git text diff complexity limit exceeded") if old_lines.size > MAX_LINES || new_lines.size > MAX_LINES || old_lines.size.to_i64 * new_lines.size > MAX_CELLS
      n = old_lines.size
      m = new_lines.size
      matrix = Array(Array(Int32)).new(n + 1) { Array(Int32).new(m + 1, 0) }
      (0...n).reverse_each do |i|
        (0...m).reverse_each do |j|
          matrix[i][j] = old_lines[i] == new_lines[j] ? matrix[i + 1][j + 1] + 1 : {matrix[i + 1][j], matrix[i][j + 1]}.max
        end
      end
      ops = [] of {Char, String}
      i = 0
      j = 0
      while i < n || j < m
        if i < n && j < m && old_lines[i] == new_lines[j]
          ops << {' ', old_lines[i]}; i += 1; j += 1
        elsif i < n && (j == m || matrix[i + 1][j] >= matrix[i][j + 1])
          ops << {'-', old_lines[i]}; i += 1
        else
          ops << {'+', new_lines[j]}; j += 1
        end
      end
      a_path = PathBytes.quote("a/" + path)
      b_path = PathBytes.quote("b/" + path)
      # Git separates an unquoted whitespace-containing ---/+++ label
      # from the following timestamp field with a literal trailing tab.
      unquoted_space = path.includes?(' ') && !a_path.starts_with?('"')
      String.build do |builder|
        builder << "diff --git #{a_path} #{b_path}\n"
        builder << "new file mode #{new_mode}\n" if old_mode.nil? && new_mode
        builder << "deleted file mode #{old_mode}\n" if old_mode && new_mode.nil?
        if old_mode && new_mode && old_mode != new_mode
          builder << "old mode #{old_mode}\nnew mode #{new_mode}\n"
        end
        builder << "--- " << (old_mode ? a_path : "/dev/null")
        builder << '\t' if old_mode && unquoted_space
        builder << '\n'
        builder << "+++ " << (new_mode ? b_path : "/dev/null")
        builder << '\t' if new_mode && unquoted_space
        builder << '\n'
        start = 0
        while start < ops.size
          while start < ops.size && ops[start][0] == ' '
            start += 1
          end
          break if start == ops.size
          left = {start - context, 0}.max
          right = start
          while right < ops.size
            if ops[right][0] != ' '
              right += 1
              next
            end
            ahead = right
            while ahead < ops.size && ops[ahead][0] == ' '
              ahead += 1
            end
            if ahead == ops.size || ahead - right > 2 * context
              right = {right + context, ops.size}.min
              break
            end
            right = ahead
          end
          right = ops.size if right >= ops.size
          old_before = ops[0...left].count { |op| op[0] != '+' }
          new_before = ops[0...left].count { |op| op[0] != '-' }
          old_len = ops[left...right].count { |op| op[0] != '+' }
          new_len = ops[left...right].count { |op| op[0] != '-' }
          old_start = old_len == 0 ? old_before : old_before + 1
          new_start = new_len == 0 ? new_before : new_before + 1
          builder << "@@ -#{old_start},#{old_len} +#{new_start},#{new_len} @@\n"
          ops[left...right].each do |tag, line|
            builder << tag << line
            unless line.ends_with?('\n')
              builder << "\n\\ No newline at end of file\n"
            end
          end
          start = right
        end
      end
    end
  end
end
