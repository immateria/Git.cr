module Git
  # :nodoc:
  # Byte-aware attributes shared by conversion and patch rendering.
  class Attributes
    enum Kind
      Unspecified
      Set
      Unset
      String
    end

    record Value, kind : Kind = Kind::Unspecified, text : String? = nil
    private record Token, name : String, value : Value
    private record Rule, base : String, basename_only : Bool,
      pattern : Array(Ignore::Token), tokens : Array(Token)

    @rules = {} of String => Array(Rule)
    @macros = {} of String => Array(Token)
    @index_blobs : Hash(String, String)?
    @trees = {} of String => Hash(String, {String, String})
    @tree_bytes = 0_i64
    @bytes_read = 0_i64
    @rule_count = 0
    @global : Array(Rule)
    @info : Array(Rule)

    # A non-nil blob map is the complete selected attribute source; nil
    # entries are deletions. It never falls back to working/index attrs.
    def initialize(@repository : Repository, *, config : Config? = nil,
                   @attribute_tree : String? = nil,
                   @attribute_blobs : Hash(String, String?)? = nil,
                   @max_bytes : Int32 = 8_388_608,
                   @max_index_bytes : Int32 = 8_388_608, @check : Proc(Nil)? = nil)
      raise ArgumentError.new("invalid Git attribute byte budget") if @max_bytes < 1
      raise ArgumentError.new("invalid Git attribute index byte budget") if @max_index_bytes < 128
      raise ArgumentError.new("conflicting Git attribute sources") if @attribute_tree && @attribute_blobs
      @macros["binary"] = [Token.new("diff", Value.new(Kind::Unset)),
                           Token.new("merge", Value.new(Kind::Unset)),
                           Token.new("text", Value.new(Kind::Unset))]
      selected = config || @repository.config
      @global = [] of Rule
      if file = selected.value?("core.attributesfile")
        unless file.empty?
          # Explicit paths only; no ambient HOME expansion.
          full = file.starts_with?('/') ? file : ::File.join(@repository.root, file)
          @global = parse(read_file(full), "", true)
        end
      end
      rules_for("")
      @info = parse(read_file(::File.join(@repository.common_dir, "info", "attributes")), "", true)
    end

    def resolve(path : String, attribute : String) : Value
      resolve(path)[attribute]? || Value.new
    end

    def resolve(path : String) : Hash(String, Value)
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      @check.try &.call
      slash = path.to_slice.rindex('/'.ord.to_u8)
      directory = slash ? path.byte_slice(0, slash) : ""
      name = slash ? path.byte_slice(slash + 1) : path
      selected = @global.dup
      selected.concat(rules_for(""))
      prefix = ""
      unless directory.empty?
        directory.split('/').each do |component|
          prefix = prefix.empty? ? component : "#{prefix}/#{component}"
          selected.concat(rules_for(prefix))
        end
      end
      selected.concat(@info)
      values = {} of String => Value
      selected.reverse_each do |rule|
        @check.try &.call
        next unless rule.base.empty? || path.starts_with?(rule.base + "/")
        tail = rule.base.empty? ? path : path.byte_slice(rule.base.bytesize + 1)
        candidate = rule.basename_only ? name : tail
        next unless Ignore.match_tokens?(rule.pattern, candidate.to_slice)
        rule.tokens.reverse_each { |token| apply(values, token, 0) }
      end
      values
    end

    # !text resolves to Unspecified and blocks earlier text. An unset macro
    # similarly prevents an earlier Set instance from expanding.
    private def apply(values : Hash(String, Value), token : Token, depth : Int32) : Nil
      return if values.has_key?(token.name)
      @check.try &.call
      raise Error.new("Git attribute macro depth exceeded") if depth > 64
      values[token.name] = token.value
      if token.value.kind.set? && (expanded = @macros[token.name]?)
        expanded.reverse_each { |part| apply(values, part, depth + 1) }
      end
    end

    private def rules_for(directory : String) : Array(Rule)
      @rules[directory] ||= begin
        relative = directory.empty? ? ".gitattributes" : "#{directory}/.gitattributes"
        data = if blobs = @attribute_blobs
                 oid = blobs[relative]?
                 oid ? blob(oid) : nil
               elsif tree = @attribute_tree
                 tree_attribute(tree, relative)
               else
                 working = @repository.work_tree.try { |root| read_file(::File.join(root, relative)) }
                 working || index_blobs[relative]?.try { |oid| blob(oid) }
               end
        parse(data, directory, directory.empty?)
      end
    end

    private def index_blobs : Hash(String, String)
      @index_blobs ||= begin
        result = {} of String => String
        @repository.index_entries(max_bytes: @max_index_bytes, check: @check).each do |entry|
          @check.try &.call
          next unless ::File.basename(entry.path) == ".gitattributes" &&
                      {"100644", "100755"}.includes?(entry.mode) && (entry.stage == 0 || entry.stage == 2)
          result[entry.path] = entry.oid if entry.stage == 0 || !result.has_key?(entry.path)
        end
        result
      end
    end

    private def tree_attribute(root : String, path : String) : String?
      parts = path.split('/')
      tree = root
      parts.each_with_index do |name, index|
        entries = @trees[tree]? || begin
          kind, data = @repository.object(tree, @max_bytes) { @check.try &.call }
          raise Error.new("Git attributes expected a tree") unless kind == "tree"
          @tree_bytes += data.bytesize
          raise Error.new("Git attribute tree byte budget exceeded") if @tree_bytes > @max_bytes
          parsed = {} of String => {String, String}
          Tree.each_entry(data, @repository.object_format) do |mode, entry_name, oid|
            @check.try &.call
            parsed[entry_name] = {mode, oid}
          end
          @trees[tree] = parsed
        end
        entry = entries[name]?
        return nil unless entry
        mode, oid = entry
        if index == parts.size - 1
          return {"100644", "100755"}.includes?(mode) ? blob(oid) : nil
        end
        return nil unless mode == "40000"
        tree = oid
      end
      nil
    end

    private def blob(oid : String) : String
      kind, data = @repository.object(oid, @max_bytes) { @check.try &.call }
      raise Error.new("Git attributes expected a blob") unless kind == "blob"
      account(data)
      data
    end

    private def account(data : String) : Nil
      @bytes_read += data.bytesize
      raise Error.new("Git attribute byte budget exceeded") if @bytes_read > @max_bytes
      raise Error.new("invalid Git attribute data") if data.includes?('\0')
    end

    # Missing and symlinked files use the index fallback. Pinned directories
    # and O_NOFOLLOW/O_NONBLOCK prevent symlink/FIFO attribute redirection.
    private def read_file(path : String) : String?
      @check.try &.call
      absolute = ::File.expand_path(path)
      parent = "/"
      ::File.dirname(absolute).split('/').reject(&.empty?).each do |component|
        @check.try &.call
        parent = ::File.join(parent, component)
        return nil if ::File.symlink?(parent) || !::Dir.exists?(parent)
      end
      dir = DescriptorPath::Directory.open(::File.dirname(absolute))
      leaf = ::File.basename(absolute)
      begin
        before = dir.stat?(leaf)
        return nil unless before
        return nil if (before.st_mode & LibC::S_IFMT) == LibC::S_IFLNK
        raise Error.new("Git attributes are not a regular file") unless (before.st_mode & LibC::S_IFMT) == LibC::S_IFREG
        cap = @max_bytes.to_i64 - @bytes_read
        raise Error.new("Git attribute byte budget exceeded") if before.st_size > cap
        file = dir.open_file(leaf, LibC::O_RDONLY | LibC::O_NONBLOCK)
        begin
          opened = file.info
          raise Error.new("Git attributes changed before read") unless opened.type.file? && dir.same_inode?(leaf, file)
          buffer = IO::Memory.new
          IO.copy(file, buffer, cap + 1)
          @check.try &.call
          after = file.info
          raise Error.new("Git attributes changed during read") unless opened.same_file?(after) &&
                                                                       opened.size == after.size && opened.modification_time == after.modification_time &&
                                                                       buffer.size == after.size && dir.same_inode?(leaf, file) &&
                                                                       dir.attached_at?(::File.dirname(absolute))
          data = buffer.to_s
          account(data)
          data.starts_with?("\uFEFF") ? data.byte_slice(3) : data
        ensure
          file.close unless file.closed?
        end
      ensure
        dir.close
      end
    rescue ex : IO::Error
      raise Error.new("Git attribute I/O invalid: #{ex.class}")
    end

    private def parse(data : String?, base : String, allow_macros : Bool) : Array(Rule)
      rules = [] of Rule
      return rules unless data
      data.each_line do |raw|
        @check.try &.call
        next if raw.bytesize >= 2048
        line = raw.chomp.strip(" \t\r\n")
        next if line.empty? || line.starts_with?('#')
        pattern, rest = split_pattern(line)
        next unless pattern
        tokens = [] of Token
        valid = true
        position = 0
        while position < rest.bytesize
          while position < rest.bytesize && attribute_blank?(rest.byte_at(position))
            position += 1
          end
          break if position == rest.bytesize
          start = position
          while position < rest.bytesize && !attribute_blank?(rest.byte_at(position))
            position += 1
          end
          raw_token = rest.byte_slice(start, position - start)
          if token = parse_token(raw_token)
            tokens << token
          else
            valid = false
            break
          end
        end
        next unless valid
        if pattern.starts_with?("[attr]")
          name = pattern.byte_slice(6)
          @macros[name] = tokens if allow_macros && valid_name?(name)
          next
        end
        next if tokens.empty?
        next if pattern.starts_with?('!') || pattern.ends_with?('/') || pattern.bytesize > 256
        anchored = pattern.starts_with?('/')
        pattern = pattern.byte_slice(1) if anchored
        next if pattern.empty?
        basename_only = !anchored && !pattern.includes?('/')
        _, compiled = begin
          Ignore.compile_pattern(pattern)
        rescue Error
          next
        end
        rules << Rule.new(base, basename_only, compiled, tokens)
        @rule_count += 1
        raise Error.new("Git attribute rule budget exceeded") if @rule_count > 4096
      end
      rules
    end

    private def parse_token(raw : String) : Token?
      return nil if raw.empty?
      kind = Kind::Set
      name = raw
      text = nil.as(String?)
      if raw.starts_with?('-') || raw.starts_with?('!')
        kind = raw.starts_with?('-') ? Kind::Unset : Kind::Unspecified
        name = raw.byte_slice(1)
      elsif equals = raw.byte_index('=')
        name = raw.byte_slice(0, equals)
        text = raw.byte_slice(equals + 1)
        kind = Kind::String
      end
      return nil unless valid_name?(name)
      Token.new(name, Value.new(kind, text))
    end

    private def valid_name?(name : String) : Bool
      return false if name.empty? || name.starts_with?('-') || name.starts_with?("builtin_")
      name.each_byte.all? do |byte|
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) || byte == 45 || byte == 46 || byte == 95
      end
    end

    private def split_pattern(line : String) : {String?, String}
      unless line.starts_with?('"')
        position = 0
        while position < line.bytesize && !attribute_blank?(line.byte_at(position))
          position += 1
        end
        return position < line.bytesize ? {line.byte_slice(0, position), line.byte_slice(position + 1)} : {line, ""}
      end
      out = IO::Memory.new
      position = 1
      while position < line.bytesize
        byte = line.byte_at(position)
        if byte == 34
          following = position + 1
          return {out.to_s, line.byte_slice(following)}
        elsif byte == 92
          position += 1
          return {nil, ""} if position >= line.bytesize
          escaped = line.byte_at(position)
          decoded = case escaped
                    when  97 then 7
                    when  98 then 8
                    when 116 then 9
                    when 110 then 10
                    when 118 then 11
                    when 102 then 12
                    when 114 then 13
                    when  34 then 34
                    when  92 then 92
                    else
                      if escaped >= 48 && escaped <= 51 && position + 2 < line.bytesize &&
                         line.byte_at(position + 1) >= 48 && line.byte_at(position + 1) <= 55 &&
                         line.byte_at(position + 2) >= 48 && line.byte_at(position + 2) <= 55
                        value = (escaped - 48).to_i * 64 + (line.byte_at(position + 1) - 48).to_i * 8 + (line.byte_at(position + 2) - 48).to_i
                        position += 2
                        value
                      else
                        return {nil, ""}
                      end
                    end
          out.write_byte(decoded.to_u8)
        else
          out.write_byte(byte)
        end
        position += 1
      end
      {nil, ""}
    end

    private def attribute_blank?(byte : UInt8) : Bool
      byte == 32 || byte == 9 || byte == 13 || byte == 10
    end
  end
end
