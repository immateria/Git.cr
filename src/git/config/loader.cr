module Git
  class Config
    # Stateful bounded parser and include traversal; not part of the
    # effective read-only configuration result.
    private class Loader
      getter entries : Array(Entry)

      def initialize(@context : Context?, @max_bytes : Int32,
                     @max_entries : Int32, @max_include_depth : Int32,
                     @remote_urls : Array(String)? = nil)
        @entries = [] of Entry
        @bytes_read = 0_i64
        @active = [] of String
        @hasconfig_seen = false
      end

      protected def hasconfig_seen? : Bool
        @hasconfig_seen
      end

      def remote_url?(name : String) : Bool
        name.starts_with?("remote.") && name.ends_with?(".url") && name.bytesize > "remote..url".bytesize
      end

      def add_command(name : String, value : String?) : Nil
        @entries << Entry.new(Key.normalize(name), value, Scope::Command, "command line:")
        raise Error.new("Git config entry budget exceeded") if @entries.size > @max_entries
      end

      def read(path : String, scope : Scope, depth : Int32, *,
               hasconfig_include : Bool = false) : Nil
        raise Error.new("Git config include depth exceeded") if depth > @max_include_depth
        return unless File.exists?(path) || File.symlink?(path)
        raise Error.new("Git config input is not a regular file") unless File.file?(path)
        absolute = File.expand_path(path)
        canonical = File.realpath(absolute)
        raise Error.new("Git config include cycle") if @active.includes?(canonical)
        @active << canonical
        begin
          max_read = @max_bytes.to_i64 - @bytes_read
          raise Error.new("Git config byte budget exceeded") if max_read < 0
          data = IO::Memory.new
          File.open(absolute) { |stream| IO.copy(stream, data, max_read + 1) }
          @bytes_read += data.size
          raise Error.new("Git config byte budget exceeded") if @bytes_read > @max_bytes
          parse(absolute, data.to_s, scope, depth, hasconfig_include)
        ensure
          @active.pop
        end
      rescue ex : File::Error
        raise Error.new("Git config file unavailable: #{ex.class}")
      end

      private def parse(origin : String, data : String, scope : Scope, depth : Int32,
                        hasconfig_include : Bool) : Nil
        # Git accepts an optional UTF-8 BOM at the beginning of a config file.
        data = data.byte_slice(3, data.bytesize - 3) if data.starts_with?("\xEF\xBB\xBF")
        section = nil.as(String?)
        subsection = nil.as(String?)
        combined = ""
        data.split('\n').each do |physical|
          physical = physical.byte_slice(0, physical.bytesize - 1) if physical.ends_with?('\r')
          count = 0
          while count < physical.bytesize && physical.byte_at(physical.bytesize - 1 - count) == 92_u8
            count += 1
          end
          continuation = count.odd?
          combined += continuation ? physical.byte_slice(0, physical.bytesize - 1) : physical
          next if continuation
          line = combined.lstrip
          combined = ""
          next if line.empty? || line.starts_with?('#') || line.starts_with?(';')
          if line.starts_with?('[')
            section, subsection = parse_section(line)
            next
          end
          raise Error.new("Git config variable outside section") unless current = section
          key, value = parse_assignment(line)
          name = current + (subsection ? "." + subsection.not_nil! : "") + "." + key
          if hasconfig_include && remote_url?(name)
            raise Error.new("Git config included via hasconfig must not define remote URLs")
          end
          @entries << Entry.new(name, value, scope, origin)
          raise Error.new("Git config entry budget exceeded") if @entries.size > @max_entries
          if name == "include.path" && value
            read(include_path(origin, value), scope, depth + 1, hasconfig_include: hasconfig_include)
          elsif current == "includeif" && key == "path" && value && subsection
            condition = subsection.not_nil!
            is_hasconfig = condition.starts_with?("hasconfig:")
            @hasconfig_seen = true if is_hasconfig
            if conditional?(condition, origin)
              read(include_path(origin, value), scope, depth + 1,
                hasconfig_include: hasconfig_include || is_hasconfig)
            end
          end
        end
        raise Error.new("Git config dangling line continuation") unless combined.empty?
      end

      private def parse_section(line : String) : {String, String?}
        # Modern headers preserve subsection case, while legacy dotted headers
        # fold it to lowercase. Neither form permits text after ] except comment.
        match = /\A\[([A-Za-z][A-Za-z0-9.-]*)(?:[ \t]+"((?:\\.|[^"\\])*)")?\][ \t]*(?:[;#].*)?\z/.match(line)
        raise Error.new("malformed Git config section") unless match
        name = match[1]
        subsection = match[2]?
        if subsection
          raise Error.new("invalid Git config subsection header") if name.includes?('.')
          {name.downcase, decode_quoted(subsection)}
        elsif point = name.index('.')
          {name.byte_slice(0, point).downcase, name.byte_slice(point + 1, name.bytesize - point - 1).downcase}
        else
          {name.downcase, nil}
        end
      end

      private def parse_assignment(line : String) : {String, String?}
        match = /\A([A-Za-z][A-Za-z0-9-]*)(.*)\z/.match(line)
        raise Error.new("invalid Git config variable name") unless match
        key = match[1].downcase
        rest = match[2].lstrip
        return {key, nil} if rest.empty? || rest.starts_with?('#') || rest.starts_with?(';')
        raise Error.new("malformed Git config assignment") unless rest.starts_with?('=')
        {key, decode_value(rest.byte_slice(1, rest.bytesize - 1).lstrip)}
      end

      private def decode_quoted(raw : String) : String
        decode_value("\"" + raw + "\"")
      end

      private def decode_value(raw : String) : String
        buffer = String::Builder.new
        quoted = false
        last_significant = 0
        bytes = raw.to_slice
        pos = 0
        while pos < bytes.size
          ch = bytes[pos]
          case ch
          when 34_u8 # double quote
            quoted = !quoted
          when 35_u8, 59_u8 # hash / semicolon
            break unless quoted
            buffer.write_byte(ch)
            last_significant = buffer.bytesize
          when 92_u8 # backslash
            pos += 1
            raise Error.new("invalid Git config escape") if pos >= bytes.size
            replacement = case bytes[pos]
                          when 110_u8 then 10_u8
                          when 116_u8 then 9_u8
                          when  98_u8 then 8_u8
                          when  34_u8 then 34_u8
                          when  92_u8 then 92_u8
                          else             raise Error.new("invalid Git config escape")
                          end
            buffer.write_byte(replacement)
            last_significant = buffer.bytesize
          else
            buffer.write_byte(ch)
            last_significant = buffer.bytesize if quoted || (ch != 32_u8 && ch != 9_u8)
          end
          pos += 1
        end
        raise Error.new("unterminated Git config quote") if quoted
        value = buffer.to_s
        value.byte_slice(0, last_significant)
      end

      private def include_path(origin : String, path : String) : String
        if path.starts_with?("~/")
          home = @context.try(&.home)
          raise Error.new("Git config include requires explicit home") unless home
          File.expand_path(path.byte_slice(2, path.bytesize - 2), home)
        else
          File.expand_path(path, File.dirname(origin))
        end
      end

      private def conditional?(condition : String, origin : String) : Bool
        prefix, _, pattern = condition.partition(':')
        if prefix == "hasconfig"
          marker = "remote.*.url:"
          raise Error.new("unsupported Git config hasconfig selector") unless pattern.starts_with?(marker)
          return false unless urls = @remote_urls
          expected = pattern.byte_slice(marker.bytesize, pattern.bytesize - marker.bytesize)
          return urls.any? { |url| glob_match?(expected, url) }
        end
        ctx = @context
        return false unless ctx
        target = case prefix.downcase
                 when "gitdir", "gitdir/i"     then ctx.git_dir
                 when "worktree", "worktree/i" then ctx.work_tree
                 when "onbranch"               then ctx.branch
                 else                               raise Error.new("unsupported Git config includeIf condition: #{prefix}")
                 end
        return false unless target
        if prefix.downcase == "gitdir" || prefix.downcase == "gitdir/i" || prefix.downcase == "worktree" || prefix.downcase == "worktree/i"
          if pattern.starts_with?("~/")
            home = ctx.home
            raise Error.new("Git config condition requires explicit home") unless home
            pattern = File.expand_path(pattern.byte_slice(2, pattern.bytesize - 2), home)
          elsif pattern.starts_with?("./")
            pattern = File.expand_path(pattern.byte_slice(2, pattern.bytesize - 2), File.dirname(origin))
          elsif !Path[pattern].absolute?
            pattern = "**/" + pattern
          end
        end
        pattern += "**" if pattern.ends_with?('/')
        fold = prefix.downcase.ends_with?("/i")
        glob_match?(pattern, target, ignore_case: fold) ||
          (pattern.ends_with?("/**") && glob_match?(pattern, target + "/", ignore_case: fold))
      end

      private def glob_match?(pattern : String, target : String, *, ignore_case : Bool = false) : Bool
        pattern = pattern.downcase if ignore_case
        target = target.downcase if ignore_case
        regex = String.build do |builder|
          builder << "\\A"
          bytes = pattern.to_slice
          i = 0
          while i < bytes.size
            if bytes[i] == 42_u8
              first = i
              while i + 1 < bytes.size && bytes[i + 1] == 42_u8
                i += 1
              end
              recursive = i > first && (first == 0 || bytes[first - 1] == 47_u8)
              if recursive && i + 1 < bytes.size && bytes[i + 1] == 47_u8
                # At a component boundary, **/ consumes zero or more complete
                # directories. Plain ** inside a component behaves like *.
                builder << "(?:.*/)?"
                i += 1
              elsif recursive && i + 1 == bytes.size
                builder << ".*"
              else
                builder << "[^/]*"
              end
            elsif bytes[i] == 63_u8
              builder << "[^/]"
            elsif bytes[i] == 91_u8 # [abc], [a-z], [!abc]
              close = pattern.index(']', i + 1)
              if close && close > i + 1
                content = pattern.byte_slice(i + 1, close - i - 1)
                if !content.includes?('/') && !content.includes?('\\')
                  content = "^" + content.byte_slice(1) if content.starts_with?('!')
                  builder << '[' << content << ']'
                  i = close
                else
                  builder << "\\["
                end
              else
                builder << "\\["
              end
            else
              builder << Regex.escape(bytes[i].chr.to_s)
            end
            i += 1
          end
          builder << "\\z"
        end
        !Regex.new(regex).match(target).nil?
      end
    end

    # Git section/subsection/key normalization is shared by loading and queries.
    private module Key
      def self.normalize(name : String) : String
        dot = name.index('.')
        last = name.rindex('.')
        raise ArgumentError.new("invalid Git config query name") unless dot && last && dot > 0 && last < name.bytesize - 1
        section = name.byte_slice(0, dot)
        key = name.byte_slice(last + 1, name.bytesize - last - 1)
        raise ArgumentError.new("invalid Git config query name") unless /\A[A-Za-z][A-Za-z0-9-]*\z/.matches?(section) &&
                                                                        /\A[A-Za-z][A-Za-z0-9-]*\z/.matches?(key)
        section.downcase + name.byte_slice(dot, last - dot + 1) + key.downcase
      end
    end
  end
end
