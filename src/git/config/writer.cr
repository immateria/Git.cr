module Git
  class Config
    # An explicitly requested, single-file Git config mutation. This is a
    # filesystem capability, not a repository admission or agent permission.
    # The caller must authorize the target path before invoking it.
    # Mutations hold Git's adjacent O_EXCL .lock from read through rename.
    class FileEditor
      MAX_BYTES = 8_388_608

      private record Occurrence, name : String, start : Int32, finish : Int32
      private record Patch, start : Int32, finish : Int32, text : String

      private class Section
        getter name : String
        getter start : Int32
        property finish : Int32

        def initialize(@name : String, @start : Int32, @finish : Int32)
        end
      end

      enum Operation
        Set
        Add
        ReplaceAll
        Unset
        UnsetAll
      end

      # Ordinary Git config assignment: refuse ambiguous multivalues.
      def self.set(path : String, name : String, value : String, *, max_bytes : Int32 = MAX_BYTES) : Nil
        edit(path, name, value, Operation::Set, max_bytes)
      end

      def self.add(path : String, name : String, value : String, *, max_bytes : Int32 = MAX_BYTES) : Nil
        edit(path, name, value, Operation::Add, max_bytes)
      end

      def self.replace_all(path : String, name : String, value : String, *, max_bytes : Int32 = MAX_BYTES) : Nil
        edit(path, name, value, Operation::ReplaceAll, max_bytes)
      end

      # Both unset forms refuse absent names. Unset refuses multivalues.
      def self.unset(path : String, name : String, *, max_bytes : Int32 = MAX_BYTES) : Nil
        edit(path, name, nil, Operation::Unset, max_bytes)
      end

      def self.unset_all(path : String, name : String, *, max_bytes : Int32 = MAX_BYTES) : Nil
        edit(path, name, nil, Operation::UnsetAll, max_bytes)
      end

      # Remove every section with this name and all of its variables, as
      # `git config --remove-section` does. Returns whether one existed.
      def self.remove_section(path : String, section : String, *, max_bytes : Int32 = MAX_BYTES) : Bool
        wanted = normalize_section(section)
        found = false
        transform(path, max_bytes) do |data|
          sections, _ = scan(data)
          matching = sections.select { |candidate| candidate.name == wanted }
          found = !matching.empty?
          splice(data, matching.map { |candidate| Patch.new(candidate.start, candidate.finish, "") })
        end
        found
      end

      # Rename every section with this name (`git config --rename-section`).
      def self.rename_section(path : String, from : String, to : String, *, max_bytes : Int32 = MAX_BYTES) : Bool
        old_name = normalize_section(from)
        new_name = normalize_section(to)
        found = false
        transform(path, max_bytes) do |data|
          sections, _ = scan(data)
          patches = sections.select { |candidate| candidate.name == old_name }.map do |candidate|
            header_end = data.byte_index(']'.ord, candidate.start) || raise Error.new("invalid Git config section")
            Patch.new(data.byte_index('['.ord, candidate.start).not_nil!, header_end + 1, render_header(new_name))
          end
          found = !patches.empty?
          splice(data, patches)
        end
        found
      end

      # "Remote.Origin" => "remote.Origin": the section is case-insensitive,
      # the subsection is not.
      private def self.normalize_section(name : String) : String
        raise Error.new("unsupported Git config section") if name.empty? || name.to_slice.any? { |byte| byte == 0_u8 || byte == 10_u8 || byte == 13_u8 }
        dot = name.byte_index('.')
        return name.downcase unless dot
        name.byte_slice(0, dot).downcase + name.byte_slice(dot, name.bytesize - dot)
      end

      private def self.splice(data : String, patches : Array(Patch)) : String
        cursor = 0
        String.build do |builder|
          patches.sort_by! { |patch| {patch.start, patch.finish} }.each do |patch|
            raise Error.new("overlapping Git config edits") if patch.start < cursor
            builder << data.byte_slice(cursor, patch.start - cursor)
            builder << patch.text
            cursor = patch.finish
          end
          builder << data.byte_slice(cursor, data.bytesize - cursor)
        end
      end

      private def self.edit(path : String, name : String, value : String?, operation : Operation,
                            max_bytes : Int32) : Nil
        raise ArgumentError.new("invalid Git config write budget") if max_bytes < 128 || max_bytes > 64 * 1024 * 1024
        # Reuse the reader's exact section/key normalization. Only the direct
        # named file is edited; config includes and command values are not.
        normalized = Config.load([] of Source, commands: [{name, value}]).entries[0].name
        # The reader allows arbitrary subsection bytes. A writer must never
        # interpolate control bytes into a newly generated section header.
        if name.to_slice.any? { |byte| byte == 0_u8 || byte == 10_u8 || byte == 13_u8 }
          raise Error.new("unsupported Git config key")
        end
        raise Error.new("unsupported Git config value") if value && (value.includes?('\0') || value.includes?('\r'))
        raise Error.new("Git config write budget exceeded") if value && value.bytesize > max_bytes
        transform(path, max_bytes) { |data| rewrite(data, normalized, value, operation) }
      end

      # Read the file under its .lock, rewrite it and rename the lock into
      # place.
      private def self.transform(path : String, max_bytes : Int32, & : String -> String) : Nil
        raise ArgumentError.new("invalid Git config write budget") if max_bytes < 128 || max_bytes > 64 * 1024 * 1024
        absolute = File.expand_path(path)
        lock = absolute + ".lock"
        fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o666)
        raise Error.new("Git config lock unavailable") if fd < 0
        owned = true
        begin
          output = ""
          io = IO::FileDescriptor.new(fd)
          begin
            info = File.info?(absolute, follow_symlinks: false)
            if info && !info.type.file?
              raise Error.new("Git config target is not a regular file")
            end
            data = if info
                     File.open(absolute) do |file|
                       buffer = IO::Memory.new
                       IO.copy(file, buffer, max_bytes.to_i64 + 1)
                       raise Error.new("Git config write budget exceeded") if buffer.size > max_bytes
                       buffer.to_s
                     end
                   else
                     ""
                   end
            output = yield data
            raise Error.new("Git config write budget exceeded") if output.bytesize > max_bytes
            if info
              perm = (info.permissions.value & 0o777).to_u32
              raise Error.new("Git config lock chmod failed") if LibC.fchmod(io.fd, perm) != 0
            end
            io.write(output.to_slice)
            io.flush
            io.fsync
          ensure
            io.close
          end
          File.rename(lock, absolute)
          owned = false
          # Sync the directory entry as well as the new file contents.
          File.open(File.dirname(absolute)) { |directory| directory.fsync }
        ensure
          File.delete?(lock) if owned
        end
      rescue ex : File::Error | IO::Error
        raise Error.new("Git config write failed: #{ex.class}")
      end

      private def self.rewrite(data : String, name : String, value : String?, operation : Operation) : String
        sections, variables = scan(data)
        section_name = name.byte_slice(0, name.to_slice.rindex('.'.ord.to_u8).not_nil!)
        matches = variables.select { |entry| entry.name == name }
        if {Operation::Unset, Operation::UnsetAll}.includes?(operation)
          raise Error.new("Git config key not found") if matches.empty?
        end
        if {Operation::Set, Operation::Unset}.includes?(operation) && matches.size > 1
          raise Error.new("Git config key has multiple values")
        end
        patches = [] of Patch
        line = value ? "\t#{name.byte_slice(name.to_slice.rindex('.'.ord.to_u8).not_nil! + 1)} = #{encode(value)}\n" : ""
        case operation
        when .unset?, .unset_all?
          (operation.unset? ? matches.first(1) : matches).each do |entry|
            patches << Patch.new(entry.start, entry.finish, "")
          end
        when .set?
          if found = matches.first?
            patches << Patch.new(found.start, found.finish, line)
          else
            insert(patches, sections, data, section_name, line)
          end
        when .add?
          insert(patches, sections, data, section_name, line)
        when .replace_all?
          matches.each { |entry| patches << Patch.new(entry.start, entry.finish, "") }
          insert(patches, sections, data, section_name, line)
        end
        # Reject ambiguous physical patch ranges instead of risking truncation.
        cursor = 0
        String.build do |builder|
          patches.sort_by! { |patch| {patch.start, patch.finish} }.each do |patch|
            raise Error.new("overlapping Git config edits") if patch.start < cursor
            builder << data.byte_slice(cursor, patch.start - cursor)
            builder << patch.text
            cursor = patch.finish
          end
          builder << data.byte_slice(cursor, data.bytesize - cursor)
        end
      end

      private def self.insert(patches : Array(Patch), sections : Array(Section), data : String,
                              section_name : String, line : String) : Nil
        if section = sections.reverse_each.find { |candidate| candidate.name == section_name }
          pos = section.finish
          separator = pos > 0 && data.byte_at(pos - 1) != 10_u8 ? "\n" : ""
          patches << Patch.new(pos, pos, separator + line)
        else
          pos = data.bytesize
          separator = pos > 0 && data.byte_at(pos - 1) != 10_u8 ? "\n" : ""
          label = render_header(section_name)
          patches << Patch.new(pos, pos, separator + label + "\n" + line)
        end
      end

      private def self.render_header(name : String) : String
        dot = name.byte_index('.')
        return "[#{name}]" unless dot
        section = name.byte_slice(0, dot)
        sub = name.byte_slice(dot + 1, name.bytesize - dot - 1)
        escaped = sub.gsub("\\", "\\\\").gsub("\"", "\\\"")
        "[#{section} \"#{escaped}\"]"
      end

      private def self.encode(value : String) : String
        quote = value.starts_with?(' ') || value.ends_with?(' ') || value.includes?('#') ||
                value.includes?(';') || value.includes?('"') || value.includes?('\\') ||
                value.includes?('\n') || value.includes?('\t') || value.includes?('\b')
        return value unless quote
        escaped = String.build do |builder|
          value.each_char do |char|
            case char
            when '\\' then builder << "\\\\"
            when '"'  then builder << "\\\""
            when '\n' then builder << "\\n"
            when '\t' then builder << "\\t"
            when '\b' then builder << "\\b"
            else           builder << char
            end
          end
        end
        "\"#{escaped}\""
      end

      private def self.scan(data : String) : {Array(Section), Array(Occurrence)}
        sections = [] of Section
        variables = [] of Occurrence
        current = nil.as(String?)
        offset = 0
        continued = ""
        record_start = 0
        data.each_line(chomp: false) do |physical|
          plain = physical.ends_with?('\n') ? physical.byte_slice(0, physical.bytesize - 1) : physical
          plain = plain.byte_slice(0, plain.bytesize - 1) if plain.ends_with?('\r')
          record_start = offset if continued.empty?
          offset += physical.bytesize
          count = 0
          while count < plain.bytesize && plain.byte_at(plain.bytesize - 1 - count) == 92_u8
            count += 1
          end
          continuation = count.odd?
          continued += continuation ? plain.byte_slice(0, plain.bytesize - 1) : plain
          next if continuation
          line = continued.lstrip
          continued = ""
          next if line.empty? || line.starts_with?('#') || line.starts_with?(';')
          if line.starts_with?('[')
            section = parse_header(line)
            sections.last.finish = record_start unless sections.empty?
            sections << Section.new(section, record_start, data.bytesize)
            current = section
          else
            raise Error.new("Git config variable outside section") unless scope = current
            match = /\A([A-Za-z][A-Za-z0-9-]*)(.*)\z/.match(line)
            raise Error.new("invalid Git config variable name") unless match
            suffix = match[2].lstrip
            unless suffix.empty? || suffix.starts_with?('#') || suffix.starts_with?(';') || suffix.starts_with?('=')
              raise Error.new("invalid Git config assignment")
            end
            validate_value(suffix.byte_slice(1, suffix.bytesize - 1).lstrip) if suffix.starts_with?('=')
            variables << Occurrence.new(scope + "." + match[1].downcase, record_start, offset)
          end
        end
        raise Error.new("Git config dangling line continuation") unless continued.empty?
        {sections, variables}
      end

      # Syntax-check existing assignments so malformed quoted values cannot
      # be silently preserved in a file that the Git oracle would refuse.
      private def self.validate_value(value : String) : Nil
        quoted = false
        bytes = value.to_slice
        i = 0
        while i < bytes.size
          case bytes[i]
          when 34_u8
            quoted = !quoted
          when 35_u8, 59_u8
            break unless quoted
          when 92_u8
            i += 1
            raise Error.new("invalid Git config escape") if i >= bytes.size
            unless {110_u8, 116_u8, 98_u8, 34_u8, 92_u8}.includes?(bytes[i])
              raise Error.new("invalid Git config escape")
            end
          end
          i += 1
        end
        raise Error.new("unterminated Git config value") if quoted
      end

      private def self.validate_header_subsection(raw : String) : Nil
        bytes = raw.to_slice
        i = 0
        while i < bytes.size
          if bytes[i] == 92_u8
            i += 1
            if i >= bytes.size || !(bytes[i] == 92_u8 || bytes[i] == 34_u8)
              raise Error.new("invalid Git config subsection escape")
            end
          end
          i += 1
        end
      end

      private def self.parse_header(line : String) : String
        match = /\A\[([A-Za-z][A-Za-z0-9.-]*)(?:[ \t]+"((?:\\.|[^"\\])*)")?\][ \t]*(?:[;#].*)?\z/.match(line)
        raise Error.new("invalid Git config section") unless match
        section = match[1]
        if sub = match[2]?
          raise Error.new("invalid Git config subsection") if section.includes?('.')
          # Git section quotes permit only escaped backslash or quote.
          validate_header_subsection(sub)
          sub = sub.gsub(/\\([\\"])/) { $1 }
          section.downcase + "." + sub
        elsif dot = section.byte_index('.')
          section.byte_slice(0, dot).downcase + "." + section.byte_slice(dot + 1, section.bytesize - dot - 1).downcase
        else
          section.downcase
        end
      end
    end
  end
end
