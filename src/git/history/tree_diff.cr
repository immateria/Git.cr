module Git
  # One path that differs between two trees (`git diff-tree -r` raw output).
  record TreeChange, status : Char, old_path : String?, new_path : String?,
    old_mode : String?, new_mode : String?, old_oid : String?, new_oid : String?,
    score : Int32? = nil do
    def path : String
      (new_path || old_path).not_nil!
    end

    # "M\tpath" / "R100\told\tnew", as --name-status prints it.
    def name_status : String
      if status == 'R'
        "R#{score.to_s.rjust(3, '0')}\t#{old_path}\t#{new_path}"
      else
        "#{status}\t#{path}"
      end
    end
  end

  class Repository
    # Compare two trees recursively (`git diff-tree -r`): Added, Deleted,
    # Modified (content or executable bit) and Type-changed (file, symlink
    # or submodule) paths, sorted by path. old may be nil (a root commit's
    # diff). Revisions are peeled to trees. With renames, deletions and
    # additions of identical content are paired as R100, as `-M100%` does.
    # paths limits the output to those paths and directories.
    def diff_trees(old : String?, new : String, *, renames : Bool = false,
                   paths : Array(String) = [] of String,
                   max_object_bytes : Int32 = 268_435_456,
                   max_changes : Int32 = 1_000_000,
                   check : Proc(Nil)? = nil) : Array(TreeChange)
      old_tree = old.try { |revision| peel_to(rev_parse(revision), "tree", max_object_bytes) }
      new_tree = peel_to(rev_parse(new), "tree", max_object_bytes)
      changes = [] of TreeChange
      compare_trees(old_tree, new_tree, "", paths, changes, max_object_bytes, max_changes, check)
      changes = pair_exact_renames(changes) if renames
      changes.sort_by! { |change| change.path.to_slice }
      changes
    end

    # The commit's changes against its first parent (`git show --name-status`).
    def commit_changes(revision : String = "HEAD", *, renames : Bool = true,
                       check : Proc(Nil)? = nil) : Array(TreeChange)
      oid = peel_to(rev_parse(revision), "commit", 8_388_608)
      parent = Reachability::Walker.new(self, check: check).commit_info(oid).parents.first?
      diff_trees(parent, oid, renames: renames, check: check)
    end

    private def compare_trees(old_tree : String?, new_tree : String?, prefix : String, paths : Array(String),
                              changes : Array(TreeChange), max_bytes : Int32, max_changes : Int32,
                              check : Proc(Nil)?) : Nil
      return if old_tree == new_tree
      old_entries = tree_entries(old_tree, max_bytes)
      new_entries = tree_entries(new_tree, max_bytes)
      names = (old_entries.keys + new_entries.keys).uniq
      names.each do |name|
        check.try &.call
        path = prefix.empty? ? name : "#{prefix}/#{name}"
        next unless path_selected?(path, paths)
        before = old_entries[name]?
        after = new_entries[name]?
        next if before == after
        before_tree = before && before[0] == "40000"
        after_tree = after && after[0] == "40000"
        if before_tree || after_tree
          compare_trees(before_tree ? before.not_nil![1] : nil, after_tree ? after.not_nil![1] : nil,
            path, paths, changes, max_bytes, max_changes, check)
          before = nil if before_tree
          after = nil if after_tree
        end
        if before && after
          status = file_kind(before[0]) == file_kind(after[0]) ? 'M' : 'T'
          changes << TreeChange.new(status, path, path, before[0], after[0], before[1], after[1])
        elsif before
          changes << TreeChange.new('D', path, nil, before[0], nil, before[1], nil)
        elsif after
          changes << TreeChange.new('A', nil, path, nil, after[0], nil, after[1])
        end
        raise Error.new("Git diff change budget exceeded") if changes.size > max_changes
      end
    end

    private def tree_entries(tree : String?, max_bytes : Int32) : Hash(String, {String, String})
      entries = {} of String => {String, String}
      return entries unless tree
      kind, raw = object(tree, max_bytes) { nil }
      raise Error.new("Git object #{tree} is not a tree") unless kind == "tree"
      Reachability.each_tree_entry(raw, @object_format) { |mode, name, oid| entries[name] = {mode, oid} }
      entries
    end

    private def file_kind(mode : String) : Symbol
      case mode
      when "120000" then :symlink
      when "160000" then :gitlink
      else               :file
      end
    end

    private def path_selected?(path : String, paths : Array(String)) : Bool
      return true if paths.empty?
      paths.any? do |selected|
        selected = selected.rchop('/')
        path == selected || path.starts_with?(selected + "/") || selected.starts_with?(path + "/")
      end
    end

    # Pair each addition with a deletion of the same content, preferring
    # one with the same file name, as Git's exact rename detection does.
    private def pair_exact_renames(changes : Array(TreeChange)) : Array(TreeChange)
      deleted = changes.select { |change| change.status == 'D' && change.old_mode != "160000" }
      used = Set(TreeChange).new
      result = changes.reject { |change| change.status == 'D' || change.status == 'A' }
      changes.select { |change| change.status == 'A' }.sort_by { |change| change.path.to_slice }.each do |added|
        candidates = deleted.select { |gone| !used.includes?(gone) && gone.old_oid == added.new_oid && added.new_mode != "160000" }
        source = candidates.find { |gone| File.basename(gone.path) == File.basename(added.path) } || candidates.first?
        if source
          used << source
          result << TreeChange.new('R', source.old_path, added.new_path, source.old_mode, added.new_mode,
            source.old_oid, added.new_oid, 100)
        else
          result << added
        end
      end
      deleted.each { |gone| result << gone unless used.includes?(gone) }
      changes.each { |change| result << change if change.status == 'D' && change.old_mode == "160000" }
      result
    end
  end
end
