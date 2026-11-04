module Git
  # A diff as text, file by file: what `git diff --no-color` prints.
  # Renames are exact only (identical content, as `-M100%`); Git's
  # similarity-based rename detection is not implemented.
  struct Patch
    # One file's section of a patch. Paths and modes are nil on the side
    # where the file does not exist; OIDs are the full object IDs (for a
    # working-tree side, the ID the content would have as a blob).
    record File, status : Char, old_path : String?, new_path : String?,
      old_mode : String?, new_mode : String?, old_oid : String?, new_oid : String?,
      binary : Bool, text : String do
      # Whether Git treats the content as binary (a NUL in its first
      # 8000 bytes, or `-diff`/`binary` in `.gitattributes`); the text is
      # then a "Binary files ... differ" line.
      def binary? : Bool
        binary
      end

      def path : String
        (new_path || old_path).not_nil!
      end

      def to_s(io : IO) : Nil
        io << text
      end
    end

    include Indexable(Patch::File)

    # :nodoc:
    def initialize(@files : Array(File))
    end

    def size : Int32
      @files.size
    end

    def unsafe_fetch(index : Int) : File
      @files.unsafe_fetch(index)
    end

    # The whole patch, the sections one after another.
    def to_s(io : IO) : Nil
      @files.each { |file| io << file.text }
    end

    # :nodoc:
    # Render the file sections for changes. overrides holds the content of
    # new sides that are not stored objects (working-tree files), by path.
    protected def self.build(repository : Repository, changes : Array(TreeDiff::Change),
                             overrides : Hash(String, String), *, context : Int32, abbrev : Int32,
                             indent_heuristic : Bool, attributes : Bool = true,
                             config : Config? = nil, max_bytes : Int32, max_lines : Int32,
                             check : Proc(Nil)?) : Patch
      raise ArgumentError.new("diff context must not be negative") if context < 0
      unless abbrev >= 4 && abbrev <= repository.object_format.hexsize
        raise ArgumentError.new("diff abbrev must be between 4 and #{repository.object_format.hexsize}")
      end
      renderer = Renderer.new(repository, overrides, context, abbrev, indent_heuristic,
        attributes, config, max_bytes, max_lines, check)
      files = [] of File
      changes.each do |change|
        check.try &.call
        if change.status == 'T'
          files << renderer.section('D', change.old_path, nil, change.old_mode, nil, change.old_oid, nil)
          files << renderer.section('A', nil, change.new_path, nil, change.new_mode, nil, change.new_oid)
        else
          files << renderer.section(change.status, change.old_path, change.new_path, change.old_mode,
            change.new_mode, change.old_oid, change.new_oid)
        end
      end
      new(files)
    end

    # :nodoc:
    # Evaluates `.gitattributes` and `$GIT_DIR/info/attributes` diff settings
    # (`diff`, `-diff`, `binary`, `diff=<driver>`) for paths in a patch.
    class Attributes
      enum DiffKind
        Unspecified
        Text
        Binary
        Driver
      end

      record Setting, kind : DiffKind = DiffKind::Unspecified, driver : String? = nil
      private record Rule, matcher : Ignore::Rule, tokens : Array(String)

      @dir_cache = {} of String => Array(Rule)
      @accumulated = {} of String => Array(Rule)
      @info_rules : Array(Rule)
      @macros = {"binary" => ["-diff", "-merge", "-text"]}

      def initialize(@repository : Repository, @max_bytes : Int32)
        if root = @repository.work_tree
          # Load root .gitattributes first so any top-level [attr] macros are known.
          @dir_cache[""] = load_file(::File.join(root, ".gitattributes"), "", allow_macros: true)
        end
        @info_rules = load_file(::File.join(@repository.git_dir, "info", "attributes"), "", allow_macros: true)
      end

      def resolve(path : String) : Setting
        slash = path.to_slice.rindex('/'.ord.to_u8)
        dir = slash ? path.byte_slice(0, slash) : ""
        name = slash ? path.byte_slice(slash + 1) : path
        rules = rules_through(dir) + @info_rules
        setting = Setting.new
        rules.each do |rule|
          tail = if rule.matcher.base.empty?
                   path
                 elsif path.starts_with?(rule.matcher.base + "/")
                   path.byte_slice(rule.matcher.base.bytesize + 1)
                 else
                   next
                 end
          next unless rule.matcher.matches?(rule.matcher.basename_only ? name : tail)
          rule.tokens.each do |token|
            setting = apply_token(setting, token)
          end
        end
        setting
      end

      private def apply_token(current : Setting, token : String) : Setting
        if token == "-diff" || token == "diff=false"
          Setting.new(DiffKind::Binary, nil)
        elsif token == "diff" || token == "diff=true"
          Setting.new(DiffKind::Text, nil)
        elsif token == "!diff"
          Setting.new(DiffKind::Unspecified, nil)
        elsif token.starts_with?("diff=")
          driver = token.byte_slice(5)
          driver.empty? ? current : Setting.new(DiffKind::Driver, driver)
        elsif expanded = @macros[token]?
          expanded.reduce(current) { |acc, sub| apply_token(acc, sub) }
        else
          current
        end
      end

      private def rules_through(directory : String) : Array(Rule)
        @accumulated[directory] ||= begin
          if directory.empty?
            rules_for("")
          else
            slash = directory.to_slice.rindex('/'.ord.to_u8)
            rules_through(slash ? directory.byte_slice(0, slash) : "") + rules_for(directory)
          end
        end
      end

      private def rules_for(directory : String) : Array(Rule)
        @dir_cache[directory] ||= begin
          if root = @repository.work_tree
            relative = directory.empty? ? ".gitattributes" : "#{directory}/.gitattributes"
            load_file(::File.join(root, relative), directory, allow_macros: directory.empty?)
          else
            [] of Rule
          end
        end
      end

      private def load_file(full_path : String, base : String, *, allow_macros : Bool) : Array(Rule)
        return [] of Rule unless ::File.exists?(full_path) && !::File.symlink?(full_path) && ::File.file?(full_path)
        return [] of Rule if ::File.size(full_path) > @max_bytes
        data = ::File.read(full_path)
        return [] of Rule unless data.valid_encoding? && !data.includes?('\0')
        rules = [] of Rule
        data.each_line do |raw|
          line = raw.chomp.strip
          next if line.empty? || line.starts_with?('#')
          pattern, rest = split_pattern(line)
          next unless pattern && !rest.empty?
          tokens = rest.split
          if allow_macros && pattern.starts_with?("[attr]")
            macro_name = pattern.byte_slice(6)
            @macros[macro_name] = tokens unless macro_name.empty?
            next
          end
          next if pattern.starts_with?('!') || pattern.ends_with?('/')
          next if pattern.bytesize > 256
          anchored = pattern.starts_with?('/')
          pattern = pattern.byte_slice(1) if anchored
          next if pattern.empty?
          basename_only = !anchored && !pattern.includes?('/')
          source, compiled_tokens = begin
            Ignore.compile_pattern(pattern)
          rescue Error
            next
          end
          special = ->(text : String) { text.each_byte.any? { |byte| {'*'.ord, '?'.ord, '['.ord, '\\'.ord}.includes?(byte) } }
          literal = special.call(pattern) ? nil : pattern
          tail = pattern.byte_slice(1)
          suffix = basename_only && pattern.starts_with?('*') && !tail.empty? && !special.call(tail) ? tail : nil
          matcher = Ignore::Rule.new(Regex.new(source), false, false, basename_only, base, literal, suffix, compiled_tokens)
          rules << Rule.new(matcher, tokens)
        end
        rules
      end

      private def split_pattern(line : String) : {String?, String}
        if line.starts_with?('"')
          out = IO::Memory.new
          i = 1
          while i < line.bytesize
            ch = line.byte_at(i)
            if ch == '"'.ord
              return {out.to_s, line.byte_slice(i + 1).strip}
            elsif ch == '\\'.ord && i + 1 < line.bytesize
              i += 1
              out.write_byte(line.byte_at(i))
            else
              out.write_byte(ch)
            end
            i += 1
          end
          {nil, ""}
        else
          parts = line.split(/\s+/, 2)
          parts.size == 2 ? {parts[0], parts[1]} : {nil, ""}
        end
      end
    end

    # :nodoc:
    class Renderer
      @attr_matcher : Attributes?

      def initialize(@repository : Repository, @overrides : Hash(String, String), @context : Int32,
                     @abbrev : Int32, @indent_heuristic : Bool, @attributes : Bool,
                     @config : Config?, @max_bytes : Int32, @max_lines : Int32,
                     @check : Proc(Nil)?)
        @abbreviations = {} of String => String
        @attr_matcher = @attributes ? Attributes.new(@repository, @max_bytes) : nil
        @custom_drivers = {} of String => Array(TextDiff::FuncRule)?
      end

      def section(status : Char, old_path : String?, new_path : String?, old_mode : String?, new_mode : String?,
                  old_oid : String?, new_oid : String?) : File
        old_data = content(old_mode, old_oid, nil)
        new_data = content(new_mode, new_oid, new_path)
        shown_old = old_path || new_path.not_nil!
        shown_new = new_path || old_path.not_nil!
        setting = @attr_matcher.try(&.resolve(shown_new)) || Attributes::Setting.new
        driver = setting.driver
        binary = case setting.kind
                 when Attributes::DiffKind::Binary
                   true
                 when Attributes::DiffKind::Text
                   false
                 when Attributes::DiffKind::Driver
                   if driver && (cfg_bin = effective_config.boolean?("diff.#{driver}.binary")) != nil
                     cfg_bin.not_nil!
                   else
                     TextDiff.binary?(old_data.to_slice) || TextDiff.binary?(new_data.to_slice)
                   end
                 else
                   TextDiff.binary?(old_data.to_slice) || TextDiff.binary?(new_data.to_slice)
                 end
        label_old = PathBytes.quote("a/" + shown_old)
        label_new = PathBytes.quote("b/" + shown_new)
        text = String.build do |io|
          io << "diff --git " << label_old << ' ' << label_new << '\n'
          if old_mode.nil?
            io << "new file mode " << new_mode << '\n'
          elsif new_mode.nil?
            io << "deleted file mode " << old_mode << '\n'
          elsif old_mode != new_mode
            io << "old mode " << old_mode << "\nnew mode " << new_mode << '\n'
          end
          if status == 'R'
            io << "similarity index 100%\nrename from " << PathBytes.quote(old_path.not_nil!)
            io << "\nrename to " << PathBytes.quote(new_path.not_nil!) << '\n'
          end
          if old_oid != new_oid
            io << "index " << abbreviate(old_oid) << ".." << abbreviate(new_oid)
            io << ' ' << old_mode if old_mode == new_mode
            io << '\n'
            side_old = old_mode ? label_old : "/dev/null"
            side_new = new_mode ? label_new : "/dev/null"
            if binary
              io << "Binary files " << side_old << " and " << side_new << " differ\n"
            else
              custom_rules = driver ? custom_driver_rules(driver) : nil
              body = TextDiff.hunks(old_data.to_slice, new_data.to_slice, @context,
                indent_heuristic: @indent_heuristic, driver: driver, custom_rules: custom_rules,
                max_lines: @max_lines, check: @check)
              unless body.empty?
                io << "--- " << side_old << (old_mode && side_old.includes?(' ') ? "\t" : "") << '\n'
                io << "+++ " << side_new << (new_mode && side_new.includes?(' ') ? "\t" : "") << '\n'
                io << body
              end
            end
          end
        end
        File.new(status, old_path, new_path, old_mode, new_mode, old_oid, new_oid, binary, text)
      end

      private def effective_config : Config
        @config ||= @repository.config
      end

      private def custom_driver_rules(driver : String) : Array(TextDiff::FuncRule)?
        return @custom_drivers[driver] if @custom_drivers.has_key?(driver)
        @custom_drivers[driver] = if pattern = effective_config.value?("diff.#{driver}.xfuncname")
                                    [TextDiff::FuncRule.new(false, Regex.new(pattern))]
                                  else
                                    nil
                                  end
      rescue ArgumentError
        @custom_drivers[driver] = nil
      end

      private def content(mode : String?, oid : String?, override_path : String?) : String
        return "" unless oid
        return "Subproject commit #{oid}\n" if mode == "160000"
        if override_path && (text = @overrides[override_path]?)
          return text
        end
        stored : {String, String} = @repository.object(oid, @max_bytes) { @check.try &.call }
        type, data = stored
        raise Error.new("Git object #{oid} is not a blob") unless type == "blob"
        data
      end

      # The shortest unambiguous prefix of oid with at least the
      # configured number of digits, as Git prints in `index` lines.
      private def abbreviate(oid : String?) : String
        return "0" * @abbrev unless oid
        @abbreviations[oid] ||= begin
          length = @abbrev
          while length < oid.bytesize
            matches = @repository.object_ids_with_prefix(oid.byte_slice(0, length), limit: 2)
            break if matches.all? { |match| match == oid }
            length += 1
          end
          oid.byte_slice(0, length)
        end
      end
    end
  end

  class Repository
    # Git's default abbreviation length for this repository: at least 7 hex
    # digits, growing by 1 for every 2 bits above 2^14 packed objects.
    protected def default_abbrev : Int32
      count = @object_database.pack_files.approximate_object_count
      bits = 0
      while count > 0
        count >>= 1
        bits += 1
      end
      {(bits + 1) // 2, 7}.max
    end

    # The difference between two states as a patch (`git diff`). With no
    # revision it compares the index with the working tree; cached
    # compares HEAD (or the revision) with the index; two revisions
    # compare their trees; one revision without cached compares it with
    # the working tree. paths limits the files, context sets the
    # unchanged lines around each hunk, and renames pairs identical
    # deleted and added files. abbrev is the least number of digits in
    # `index` lines (when nil, scaled with the packed object count as Git
    # does, with a minimum of 7). attributes enables `.gitattributes`
    # diff drivers (`diff=<driver>`, `-diff`, `binary`). indent_heuristic
    # is diff.indentHeuristic. config supplies core.filemode and custom
    # `diff.<driver>.xfuncname`. Unmerged and intent-to-add paths raise
    # Error; submodule working trees are not inspected.
    def diff(old : String? = nil, new : String? = nil, *, cached : Bool = false,
             paths : Array(String) = [] of String, context : Int32 = 3, renames : Bool = true,
             abbrev : Int32? = nil, indent_heuristic : Bool = true,
             attributes : Bool = true,
             max_bytes : Int32 = 8_388_608, max_changes : Int32 = 1_000_000,
             max_lines : Int32 = 1_000_000, config : Config? = nil,
             check : Proc(Nil)? = nil) : Patch
      raise ArgumentError.new("a second revision needs a first one") if new && !old
      raise ArgumentError.new("cached compares one revision with the index") if new && cached
      effective_abbrev = abbrev || default_abbrev
      overrides = {} of String => String
      changes = if old && new
                  TreeDiff.compare(self, diff_tree(old, max_bytes), diff_tree(new, max_bytes).not_nil!,
                    renames: renames, paths: paths, max_object_bytes: max_bytes,
                    max_changes: max_changes, check: check)
                elsif cached
                  base = old ? diff_tree(old, max_bytes) : head_tree_oid(max_bytes)
                  TreeDiff.compare_flat(flatten_tree(base, paths, max_bytes, check),
                    index_snapshot(paths, check), renames: renames, check: check)
                else
                  require_worktree!
                  base = old ? flatten_tree(diff_tree(old, max_bytes), paths, max_bytes, check) : index_snapshot(paths, check)
                  mode_sensitive = config.try(&.boolean?("core.filemode")) != false
                  TreeDiff.compare_flat(base, worktree_snapshot(paths, mode_sensitive, max_bytes, overrides, check),
                    renames: renames, check: check)
                end
      raise Error.new("Git diff change budget exceeded") if changes.size > max_changes
      Patch.build(self, changes, overrides, context: context, abbrev: effective_abbrev,
        indent_heuristic: indent_heuristic, attributes: attributes, config: config,
        max_bytes: max_bytes, max_lines: max_lines, check: check)
    end

    private def diff_tree(revision : String, max_bytes : Int32) : String
      Revision.peel(self, rev_parse(revision), "tree", max_bytes)
    end

    private def head_tree_oid(max_bytes : Int32) : String?
      _, oid = head_ref_and_oid
      oid.try { |commit| Revision.peel(self, commit, "tree", max_bytes) }
    end

    private def flatten_tree(tree : String?, paths : Array(String), max_bytes : Int32, check : Proc(Nil)?,
                             prefix : String = "", into : Hash(String, {String, String}) = {} of String => {String, String}) : Hash(String, {String, String})
      return into unless tree
      stored : {String, String} = object(tree, max_bytes) { check.try &.call }
      type, raw = stored
      raise Error.new("Git object #{tree} is not a tree") unless type == "tree"
      Tree.each_entry(raw, object_format) do |mode, name, oid|
        check.try &.call
        path = prefix.empty? ? name : "#{prefix}/#{name}"
        next unless TreeDiff.selected?(path, paths)
        if mode == "40000"
          flatten_tree(oid, paths, max_bytes, check, path, into)
        else
          into[path] = {mode, oid}
        end
      end
      into
    end

    private def staged_entries(paths : Array(String), check : Proc(Nil)?) : Array(Index::Entry)
      entries = index_entries(check: check).select { |entry| TreeDiff.selected?(entry.path, paths) }
      entries.each do |entry|
        raise Error.new("unmerged paths cannot be diffed: #{PathBytes.quote(entry.path)}") if entry.stage != 0
        raise Error.new("intent-to-add paths cannot be diffed: #{PathBytes.quote(entry.path)}") if entry.intent
      end
      entries
    end

    private def index_snapshot(paths : Array(String), check : Proc(Nil)?) : Hash(String, {String, String})
      snapshot = {} of String => {String, String}
      staged_entries(paths, check).each { |entry| snapshot[entry.path] = {entry.mode, entry.oid} }
      snapshot
    end

    private def worktree_snapshot(paths : Array(String), mode_sensitive : Bool, max_bytes : Int32,
                                  overrides : Hash(String, String), check : Proc(Nil)?) : Hash(String, {String, String})
      snapshot = {} of String => {String, String}
      index_time = @index.modified_at
      verified = Set(String).new
      staged_entries(paths, check).each do |entry|
        check.try &.call
        if entry.skip_worktree || @worktree.stat_unchanged?(entry, mode_sensitive, index_time, verified) { check.try &.call }
          snapshot[entry.path] = {entry.mode, entry.oid}
          next
        end
        if entry.mode == "160000"
          # A submodule counts as present when its directory is; what is
          # checked out inside it is not inspected.
          directory = File.join(work_tree.not_nil!, entry.path)
          snapshot[entry.path] = {entry.mode, entry.oid} if Dir.exists?(directory) && !File.symlink?(directory)
          next
        end
        found = @worktree.snapshot(entry, max_bytes, mode_sensitive) { check.try &.call }
        next unless found
        mode, oid, data = found
        snapshot[entry.path] = {mode, oid}
        overrides[entry.path] = data unless oid == entry.oid
      end
      snapshot
    end
  end
end
