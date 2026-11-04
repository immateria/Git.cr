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
      # 8000 bytes); the text is then a "Binary files ... differ" line.
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
                             indent_heuristic : Bool, max_bytes : Int32, max_lines : Int32,
                             check : Proc(Nil)?) : Patch
      raise ArgumentError.new("diff context must not be negative") if context < 0
      unless abbrev >= 4 && abbrev <= repository.object_format.hexsize
        raise ArgumentError.new("diff abbrev must be between 4 and #{repository.object_format.hexsize}")
      end
      renderer = Renderer.new(repository, overrides, context, abbrev, indent_heuristic, max_bytes, max_lines, check)
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
    class Renderer
      def initialize(@repository : Repository, @overrides : Hash(String, String), @context : Int32,
                     @abbrev : Int32, @indent_heuristic : Bool, @max_bytes : Int32, @max_lines : Int32,
                     @check : Proc(Nil)?)
        @abbreviations = {} of String => String
      end

      def section(status : Char, old_path : String?, new_path : String?, old_mode : String?, new_mode : String?,
                  old_oid : String?, new_oid : String?) : File
        old_data = content(old_mode, old_oid, nil)
        new_data = content(new_mode, new_oid, new_path)
        binary = TextDiff.binary?(old_data.to_slice) || TextDiff.binary?(new_data.to_slice)
        shown_old = old_path || new_path.not_nil!
        shown_new = new_path || old_path.not_nil!
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
              body = TextDiff.hunks(old_data.to_slice, new_data.to_slice, @context,
                indent_heuristic: @indent_heuristic, max_lines: @max_lines, check: @check)
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
    # The difference between two states as a patch (`git diff`). With no
    # revision it compares the index with the working tree; cached
    # compares HEAD (or the revision) with the index; two revisions
    # compare their trees; one revision without cached compares it with
    # the working tree. paths limits the files, context sets the
    # unchanged lines around each hunk, and renames pairs identical
    # deleted and added files. abbrev is the least number of digits in
    # `index` lines (Git picks more for repositories with 16384 or more
    # objects). indent_heuristic is diff.indentHeuristic. config supplies
    # core.filemode. Unmerged and intent-to-add paths raise Error;
    # submodule working trees are not inspected.
    def diff(old : String? = nil, new : String? = nil, *, cached : Bool = false,
             paths : Array(String) = [] of String, context : Int32 = 3, renames : Bool = true,
             abbrev : Int32 = 7, indent_heuristic : Bool = true,
             max_bytes : Int32 = 8_388_608, max_changes : Int32 = 1_000_000,
             max_lines : Int32 = 1_000_000, config : Config? = nil,
             check : Proc(Nil)? = nil) : Patch
      raise ArgumentError.new("a second revision needs a first one") if new && !old
      raise ArgumentError.new("cached compares one revision with the index") if new && cached
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
      Patch.build(self, changes, overrides, context: context, abbrev: abbrev,
        indent_heuristic: indent_heuristic, max_bytes: max_bytes, max_lines: max_lines, check: check)
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
