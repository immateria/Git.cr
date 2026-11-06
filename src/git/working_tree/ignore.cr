require "bit_array"

module Git
  # Git-style ignore matching for local .gitignore files, info/exclude and
  # an explicitly configured core.excludesFile. Patterns match raw path bytes
  # as Git's wildmatch does (so `?` and `[...]` match a single byte, never a
  # multibyte UTF-8 sequence).
  class Ignore
    # :nodoc:
    enum TokenKind
      Byte
      AnyNonSlash
      CharClass
      Star
      StarStarSlash
      StarStarEnd
    end

    # :nodoc:
    record Token, kind : TokenKind, byte : UInt8 = 0_u8, set : BitArray? = nil

    record Rule, matcher : Regex, negated : Bool, directory_only : Bool, basename_only : Bool, base : String,
      literal : String? = nil, suffix : String? = nil, tokens : Array(Token) = [] of Token do
      # Literal names and "*.ext" basename patterns, the common cases, are
      # compared directly; the rest go through the byte-exact wildmatch tokens.
      def matches?(candidate : String) : Bool
        if exact = literal
          candidate == exact
        elsif ending = suffix
          candidate.ends_with?(ending)
        elsif !tokens.empty?
          Ignore.match_tokens?(tokens, candidate.to_slice)
        else
          matcher.matches?(candidate)
        end
      end
    end

    @cache = {} of String => Array(Rule)
    @accumulated = {} of String => Array(Rule)
    @global : Array(Rule)
    @bytes_read = 0
    @rule_count = 0

    def initialize(@root : String, @git_dir : String, @max_bytes : Int32,
                   @allowed_path : Proc(String, Bool)? = nil, *, config : Config? = nil)
      excludes = [] of Rule
      if (configured = config.try(&.value?("core.excludesfile"))) && !configured.empty?
        excludes.concat(load_rules(configured, ""))
      end
      excludes.concat(load_rules(File.join(@git_dir, "info", "exclude"), ""))
      @global = excludes
    end

    # Whether relative is ignored. Git does not descend into an ignored
    # directory, so a negation for a child cannot restore it. A caller
    # walking the tree that already skipped ignored directories passes
    # parents_checked to test only the last component.
    def ignored?(relative : String, is_directory : Bool, *, parents_checked : Bool = false) : Bool
      parts = relative.split('/')
      prefix = ""
      parts.each_with_index do |part, index|
        parent = prefix
        prefix = prefix.empty? ? part : "#{prefix}/#{part}"
        last = index == parts.size - 1
        next if parents_checked && !last
        ignored = match?(rules_through(parent), prefix, part, !last || is_directory)
        return ignored if last
        return true if ignored
      end
      false
    end

    # The rules that apply inside directory, lowest precedence first:
    # core.excludesFile (when configured), info/exclude, then each .gitignore
    # from the root down to directory.
    private def rules_through(directory : String) : Array(Rule)
      @accumulated[directory] ||= begin
        if directory.empty?
          @global + rules_for("")
        else
          slash = directory.to_slice.rindex('/'.ord.to_u8)
          rules_through(slash ? directory.byte_slice(0, slash) : "") + rules_for(directory)
        end
      end
    end

    # The last matching rule decides.
    private def match?(rules : Array(Rule), path : String, name : String, directory : Bool) : Bool
      ignored = false
      rules.each do |rule|
        next if rule.directory_only && !directory
        tail = if rule.base.empty?
                 path
               elsif path.starts_with?(rule.base + "/")
                 path.byte_slice(rule.base.bytesize + 1)
               else
                 next
               end
        ignored = !rule.negated if rule.matches?(rule.basename_only ? name : tail)
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
        source, tokens = Ignore.compile_pattern(line)
        special = ->(text : String) { text.each_byte.any? { |byte| {'*'.ord, '?'.ord, '['.ord, '\\'.ord}.includes?(byte) } }
        literal = special.call(line) ? nil : line
        rest = line.byte_slice(1)
        suffix = basename_only && line.starts_with?('*') && !rest.empty? && !special.call(rest) ? rest : nil
        rules << Rule.new(Regex.new(source), negated, directory_only, basename_only, base, literal, suffix, tokens)
        @rule_count += 1
        raise Error.new("Git ignore rule budget exceeded") if @rule_count > 4096
      end
      rules
    end

    # :nodoc:
    protected def self.compile_pattern(line : String) : {String, Array(Token)}
      tokens = [] of Token
      source = String.build do |builder|
        builder << "\\A"
        i = 0
        while i < line.bytesize
          byte = line.byte_at(i)
          ch = byte.chr
          if ch == '\\'
            i += 1
            raise Error.new("Git ignore dangling escape") if i >= line.bytesize
            escaped = line.byte_at(i)
            tokens << Token.new(TokenKind::Byte, escaped)
            if escaped < 0x80
              builder << Regex.escape(escaped.chr.to_s)
            else
              builder << '.'
            end
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
              tokens << Token.new(TokenKind::StarStarSlash)
            elsif run >= 2 && at_component_start && i + 1 == line.bytesize
              builder << ".*"
              tokens << Token.new(TokenKind::StarStarEnd)
            else
              builder << "[^/]*"
              tokens << Token.new(TokenKind::Star)
            end
          elsif ch == '?'
            builder << "[^/]"
            tokens << Token.new(TokenKind::AnyNonSlash)
          elsif ch == '['
            end_bracket = line.byte_index(']', i + 1)
            raise Error.new("unsupported Git ignore character class") unless end_bracket
            char_class = line.byte_slice(i + 1, end_bracket - i - 1)
            raise Error.new("unsupported Git ignore character class") if char_class.empty? || char_class.includes?('\\') || char_class.includes?('/')
            tokens << Token.new(TokenKind::CharClass, 0_u8, compile_char_class(char_class))
            char_class = "^" + char_class.byte_slice(1) if char_class.starts_with?('!')
            builder << '[' << char_class << ']'
            i = end_bracket
          elsif byte >= 0x80
            # A multibyte character: record each raw byte in tokens and escape
            # the UTF-8 sequence in the fallback regex.
            stop = i + 1
            while stop < line.bytesize && line.byte_at(stop) & 0xC0 == 0x80
              stop += 1
            end
            (i...stop).each { |idx| tokens << Token.new(TokenKind::Byte, line.byte_at(idx)) }
            builder << Regex.escape(line.byte_slice(i, stop - i))
            i = stop - 1
          else
            tokens << Token.new(TokenKind::Byte, byte)
            builder << Regex.escape(ch.to_s)
          end
          i += 1
        end
        builder << "\\z"
      end
      {source, tokens}
    end

    private def self.compile_char_class(raw : String) : BitArray
      bytes = raw.to_slice
      negated = false
      offset = 0
      if !bytes.empty? && (bytes[0] == '!'.ord || bytes[0] == '^'.ord)
        negated = true
        offset = 1
      end
      raise Error.new("unsupported Git ignore character class") if offset >= bytes.size
      allowed = BitArray.new(256, false)
      j = offset
      while j < bytes.size
        if j + 2 < bytes.size && bytes[j + 1] == '-'.ord
          low = bytes[j]
          high = bytes[j + 2]
          (low..high).each { |b| allowed[b.to_i] = true } if low <= high
          j += 3
        else
          allowed[bytes[j].to_i] = true
          j += 1
        end
      end
      if negated
        256.times { |b| allowed[b] = !allowed[b] }
      end
      allowed['/'.ord] = false
      allowed
    end

    # :nodoc:
    protected def self.match_tokens?(tokens : Array(Token), text : Bytes) : Bool
      memo = Set({Int32, Int32}).new
      match_tokens_at?(tokens, text, 0, 0, memo)
    end

    private def self.match_tokens_at?(tokens : Array(Token), text : Bytes, ti : Int32, si : Int32,
                                      failed : Set({Int32, Int32})) : Bool
      return si == text.size if ti == tokens.size
      state = {ti, si}
      return false if failed.includes?(state)
      token = tokens[ti]
      matched = case token.kind
                when TokenKind::Byte
                  si < text.size && text[si] == token.byte && match_tokens_at?(tokens, text, ti + 1, si + 1, failed)
                when TokenKind::AnyNonSlash
                  si < text.size && text[si] != '/'.ord.to_u8 && match_tokens_at?(tokens, text, ti + 1, si + 1, failed)
                when TokenKind::CharClass
                  set = token.set.not_nil!
                  si < text.size && set[text[si].to_i] && match_tokens_at?(tokens, text, ti + 1, si + 1, failed)
                when TokenKind::Star
                  match_tokens_at?(tokens, text, ti + 1, si, failed) ||
                    (si < text.size && text[si] != '/'.ord.to_u8 && match_tokens_at?(tokens, text, ti, si + 1, failed))
                when TokenKind::StarStarSlash
                  if match_tokens_at?(tokens, text, ti + 1, si, failed)
                    true
                  else
                    found = false
                    k = si
                    while k < text.size
                      if text[k] == '/'.ord.to_u8 && match_tokens_at?(tokens, text, ti + 1, k + 1, failed)
                        found = true
                        break
                      end
                      k += 1
                    end
                    found
                  end
                when TokenKind::StarStarEnd
                  true
                else
                  false
                end
      failed << state unless matched
      matched
    end
  end
end
