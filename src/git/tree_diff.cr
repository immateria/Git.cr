require "set"

module Git
  # Path-level differences between two trees, as `git diff-tree -r`
  # reports them. Content differences inside a file are TextDiff's job.
  module TreeDiff
    # One path that differs between two trees (`git diff-tree -r` raw output).
    record Change, status : Char, old_path : String?, new_path : String?,
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

    # Compare two trees (old may be nil, as for a root commit), sorted by
    # path. With renames, deletions and additions of identical content are
    # paired as R100. paths limits the output to those paths and
    # directories.
    def self.compare(repository : Repository, old_tree : String?, new_tree : String, *,
                     renames : Bool = false, paths : Array(String) = [] of String,
                     max_object_bytes : Int32 = 268_435_456, max_changes : Int32 = 1_000_000,
                     check : Proc(Nil)? = nil) : Array(Change)
      changes = [] of Change
      walk(repository, old_tree, new_tree, "", paths, changes, max_object_bytes, max_changes, check)
      changes = pair_exact_renames(changes) if renames
      changes.sort_by! { |change| change.path.to_slice }
      changes
    end

    private def self.walk(repository : Repository, old_tree : String?, new_tree : String?, prefix : String,
                          paths : Array(String), changes : Array(Change), max_bytes : Int32,
                          max_changes : Int32, check : Proc(Nil)?) : Nil
      return if old_tree == new_tree
      old_entries = entries(repository, old_tree, max_bytes)
      new_entries = entries(repository, new_tree, max_bytes)
      (old_entries.keys + new_entries.keys).uniq.each do |name|
        check.try &.call
        path = prefix.empty? ? name : "#{prefix}/#{name}"
        next unless selected?(path, paths)
        before = old_entries[name]?
        after = new_entries[name]?
        next if before == after
        before_tree = before && before[0] == "40000"
        after_tree = after && after[0] == "40000"
        if before_tree || after_tree
          walk(repository, before_tree ? before.not_nil![1] : nil, after_tree ? after.not_nil![1] : nil,
            path, paths, changes, max_bytes, max_changes, check)
          before = nil if before_tree
          after = nil if after_tree
        end
        if before && after
          status = kind(before[0]) == kind(after[0]) ? 'M' : 'T'
          changes << Change.new(status, path, path, before[0], after[0], before[1], after[1])
        elsif before
          changes << Change.new('D', path, nil, before[0], nil, before[1], nil)
        elsif after
          changes << Change.new('A', nil, path, nil, after[0], nil, after[1])
        end
        raise Error.new("Git diff change budget exceeded") if changes.size > max_changes
      end
    end

    private def self.entries(repository : Repository, tree : String?, max_bytes : Int32) : Hash(String, {String, String})
      by_name = {} of String => {String, String}
      return by_name unless tree
      # A typed binding: Crystal 1.13 cannot type the destructuring form of
      # this call inside the recursive comparison.
      stored : {String, String} = repository.object(tree, max_bytes) { nil }
      type, raw = stored
      raise Error.new("Git object #{tree} is not a tree") unless type == "tree"
      Tree.each_entry(raw, repository.object_format) { |mode, name, oid| by_name[name] = {mode, oid} }
      by_name
    end

    private def self.kind(mode : String) : Symbol
      case mode
      when "120000" then :symlink
      when "160000" then :gitlink
      else               :file
      end
    end

    private def self.selected?(path : String, paths : Array(String)) : Bool
      return true if paths.empty?
      paths.any? do |selected|
        selected = selected.rchop('/')
        path == selected || path.starts_with?(selected + "/") || selected.starts_with?(path + "/")
      end
    end

    # Pair each addition with a deletion of the same content, preferring
    # one with the same file name, as Git's exact rename detection does.
    private def self.pair_exact_renames(changes : Array(Change)) : Array(Change)
      deleted = changes.select { |change| change.status == 'D' && change.old_mode != "160000" }
      used = Set(Change).new
      result = changes.reject { |change| change.status == 'D' || change.status == 'A' }
      changes.select { |change| change.status == 'A' }.sort_by { |change| change.path.to_slice }.each do |added|
        candidates = deleted.select { |gone| !used.includes?(gone) && gone.old_oid == added.new_oid && added.new_mode != "160000" }
        source = candidates.find { |gone| File.basename(gone.path) == File.basename(added.path) } || candidates.first?
        if source
          used << source
          result << Change.new('R', source.old_path, added.new_path, source.old_mode, added.new_mode,
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

  class Repository
    # Compare two revisions' trees recursively (`git diff-tree -r`): Added,
    # Deleted, Modified (content or executable bit) and Type-changed (file,
    # symlink or submodule) paths, sorted by path. old may be nil (a root
    # commit's diff). With renames, identical content is paired as R100,
    # as `-M100%` does. paths limits the output to those paths and
    # directories.
    def diff_trees(old : String?, new : String, *, renames : Bool = false,
                   paths : Array(String) = [] of String,
                   max_object_bytes : Int32 = 268_435_456,
                   max_changes : Int32 = 1_000_000,
                   check : Proc(Nil)? = nil) : Array(TreeDiff::Change)
      old_tree = old.try { |revision| Revision.peel(self, rev_parse(revision), "tree", max_object_bytes) }
      new_tree = Revision.peel(self, rev_parse(new), "tree", max_object_bytes)
      TreeDiff.compare(self, old_tree, new_tree, renames: renames, paths: paths,
        max_object_bytes: max_object_bytes, max_changes: max_changes, check: check)
    end

    # The commit's changes against its first parent (`git show --name-status`).
    def commit_changes(revision : String = "HEAD", *, renames : Bool = true,
                       check : Proc(Nil)? = nil) : Array(TreeDiff::Change)
      oid = Revision.peel(self, rev_parse(revision), "commit")
      parent = History::RevisionWalker.new(self, check: check).commit_node(oid).parents.first?
      diff_trees(parent, oid, renames: renames, check: check)
    end
  end
end
