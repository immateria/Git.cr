module Git
  # Git-style ignore matching for local .gitignore files and info/exclude.
  # This intentionally does not load external excludesFile, attributes, or
  # invoke git/configured programs. Unsupported constructs fail closed.
  class Ignore
    record Rule, matcher : Regex, negated : Bool, directory_only : Bool, basename_only : Bool, base : String

    @cache = {} of String => Array(Rule)
    @global : Array(Rule)
    @bytes_read = 0
    @rule_count = 0

    def initialize(@root : String, @git_dir : String, @max_bytes : Int32,
                   @allowed_path : Proc(String, Bool)? = nil)
      @global = load_rules(File.join(@git_dir, "info", "exclude"), "")
    end

    def ignored?(relative : String, is_directory : Bool) : Bool
      parts = relative.split('/')
      rules = @global.dup
      rules.concat(rules_for(""))
      prefix = ""
      ignored = false
      parts.each_with_index do |part, index|
        prefix = prefix.empty? ? part : "#{prefix}/#{part}"
        directory = index < parts.size - 1 || is_directory
        ignored = false
        rules.each do |rule|
          next if rule.directory_only && !directory
          tail = if rule.base.empty?
                   prefix
                 elsif prefix.starts_with?(rule.base + "/")
                   prefix.byte_slice(rule.base.bytesize + 1)
                 else
                   next
                 end
          candidate = rule.basename_only ? part : tail
          ignored = !rule.negated if rule.matcher.matches?(candidate)
        end
        # Git will not descend an excluded parent directory, so a negation
        # for a child cannot restore it until the parent itself is unignored.
        return true if ignored && directory
        rules.concat(rules_for(prefix)) if index < parts.size - 1
      end
      ignored
    end

    private def rules_for(directory : String) : Array(Rule)
      @cache[directory] ||= begin
        relative = directory.empty? ? ".gitignore" : "#{directory}/.gitignore"
        path = File.join(@root, relative)
        if @allowed_path && !@allowed_path.not_nil!.call(relative) && (File.exists?(path) || File.symlink?(path))
          raise Error.new("Git ignore file is outside permitted read scope")
        end
        load_rules(path, directory)
      end
    end

    private def load_rules(path : String, base : String) : Array(Rule)
      return [] of Rule unless File.exists?(path) || File.symlink?(path)
      raise Error.new("Git ignore file redirected") if File.symlink?(path) || !File.file?(path) || File.realpath(path) != path
      cap = @max_bytes - @bytes_read
      raise Error.new("Git ignore byte budget exceeded") if cap <= 0 || File.size(path) > cap
      buffer = IO::Memory.new
      File.open(path) { |f| IO.copy(f, buffer, cap.to_i64 + 1) }
      raise Error.new("Git ignore byte budget exceeded") if buffer.size > cap
      data = buffer.to_s
      @bytes_read += data.bytesize
      raise Error.new("invalid Git ignore encoding") unless data.valid_encoding? && !data.includes?('\0')
      rules = [] of Rule
      data.each_line do |raw|
        line = raw.chomp
        # Ignore empty and comment lines; leading backslash escapes # or !.
        next if line.empty? || line.starts_with?('#')
        negated = line.starts_with?('!')
        line = line.byte_slice(1) if negated
        # An even number of backslashes before a trailing space leaves the
        # space unescaped. An odd number escapes the space itself.
        while line.ends_with?(' ')
          backslashes = 0
          cursor = line.bytesize - 2
          while cursor >= 0 && line.byte_at(cursor) == '\\'.ord
            backslashes += 1
            cursor -= 1
          end
          break if backslashes.odd?
          line = line.byte_slice(0, line.bytesize - 1)
        end
        next if line.empty?
        raise Error.new("Git ignore pattern too long") if line.bytesize > 256
        directory_only = line.ends_with?('/') && !line.ends_with?("\\/")
        line = line.byte_slice(0, line.bytesize - 1) if directory_only
        next if line.empty?
        anchored = line.starts_with?('/')
        line = line.byte_slice(1) if anchored
        basename_only = !anchored && !line.includes?('/')
        source = String.build do |builder|
          builder << "\\A"
          i = 0
          while i < line.bytesize
            ch = line.byte_at(i).chr
            if ch == '\\'
              i += 1
              raise Error.new("Git ignore dangling escape") if i >= line.bytesize
              builder << Regex.escape(line.byte_at(i).chr.to_s)
            elsif ch == '*'
              first = i
              while i + 1 < line.bytesize && line.byte_at(i + 1) == '*'.ord
                i += 1
              end
              run = i - first + 1
              at_component_start = first == 0 || line.byte_at(first - 1) == '/'.ord
              followed_by_slash = i + 1 < line.bytesize && line.byte_at(i + 1) == '/'.ord
              # Git's recursive ** is special at component boundaries only.
              # Else a run of stars has the same component-local meaning as *.
              if run >= 2 && at_component_start && followed_by_slash
                i += 1
                builder << "(?:.*/)?"
              elsif run >= 2 && at_component_start && i + 1 == line.bytesize
                builder << ".*"
              else
                builder << "[^/]*"
              end
            elsif ch == '?'
              builder << "[^/]"
            elsif ch == '['
              end_bracket = line.byte_index(']', i + 1)
              raise Error.new("unsupported Git ignore character class") unless end_bracket
              char_class = line.byte_slice(i + 1, end_bracket - i - 1)
              raise Error.new("unsupported Git ignore character class") if char_class.empty? || char_class.includes?('\\') || char_class.includes?('/')
              char_class = "^" + char_class.byte_slice(1) if char_class.starts_with?('!')
              builder << '[' << char_class << ']'
              i = end_bracket
            elsif line.byte_at(i) >= 0x80
              # A multibyte character: escape its whole UTF-8 sequence.
              stop = i + 1
              while stop < line.bytesize && line.byte_at(stop) & 0xC0 == 0x80
                stop += 1
              end
              builder << Regex.escape(line.byte_slice(i, stop - i))
              i = stop - 1
            else
              builder << Regex.escape(ch.to_s)
            end
            i += 1
          end
          builder << "\\z"
        end
        rules << Rule.new(Regex.new(source), negated, directory_only, basename_only, base)
        @rule_count += 1
        raise Error.new("Git ignore rule budget exceeded") if @rule_count > 4096
      end
      rules
    end
  end
end
