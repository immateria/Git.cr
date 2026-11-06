module Git
  module Checkout
    # Before collapsing a tracked directory into a file, prove that every
    # leaf and directory below it belongs to the tracked predecessor. This is
    # the native equivalent of Git refusing an update that would lose
    # untracked files. Publication rechecks with rmdir so a racing arrival is
    # preserved and reported as partial publication rather than deleted.
    protected def self.require_collapsible_directory!(root : String, prefix : String,
                                                      tracked_paths : Array(String), max_entries : Int32, *,
                                                      known_directories : Set(String) = Set(String).new) : Nil
      expected_files = tracked_paths.to_set
      expected_dirs = path_prefixes(tracked_paths) | known_directories
      raise Error.new("Git checkout transition path is not a tracked directory") unless expected_dirs.includes?(prefix)
      root_path = File.join(root, prefix)
      raise Error.new("Git checkout transition directory redirected") if File.symlink?(root_path) || !Dir.exists?(root_path)
      stack = [prefix]
      seen = 0
      until stack.empty?
        relative = stack.pop
        absolute = File.join(root, relative)
        raise Error.new("Git checkout transition directory redirected") if File.symlink?(absolute) || !Dir.exists?(absolute)
        Dir.each_child(absolute) do |name|
          seen += 1
          raise Error.new("Git checkout transition entry budget exceeded") if seen > max_entries * 2
          child = File.join(relative, name)
          child_absolute = File.join(root, child)
          if File.symlink?(child_absolute) || File.file?(child_absolute)
            raise Error.new("Git checkout refuses untracked content in directory transition") unless expected_files.includes?(child)
          elsif Dir.exists?(child_absolute)
            raise Error.new("Git checkout refuses untracked directory in transition") unless expected_dirs.includes?(child)
            stack << child
          else
            raise Error.new("Git checkout refuses unsupported untracked content in directory transition")
          end
        end
      end
    end

    # Admit new worktree destinations across clean D/F transitions. Ordinary
    # additions still require a free destination. A new file replacing a
    # tracked directory requires that the entire old subtree contain only
    # tracked leaves; a new descendant beneath a tracked file is allowed only
    # because that tracked blocker is scheduled to disappear.
    protected def self.require_transition_destinations!(root : String,
                                                        old_paths : Enumerable(String),
                                                        new_paths : Enumerable(String),
                                                        *, max_entries : Int32) : Nil
      old = old_paths.to_a.uniq
      fresh = new_paths.to_a.uniq
      require_tree_paths!(old, "Git predecessor")
      require_tree_paths!(fresh, "Git destination")
      old_set = old.to_set
      fresh.each do |path|
        next if old_set.includes?(path)
        ancestor = old.find { |candidate| path.starts_with?(candidate + "/") }
        next if ancestor
        descendants = old.select { |candidate| candidate.starts_with?(path + "/") }
        if descendants.empty?
          require_free_destination!(root, path)
        else
          require_collapsible_directory!(root, path, descendants, max_entries)
        end
      end
    end

    # Directories that block a new file must be removed deepest-first after
    # their tracked leaves are removed. Obsolete empty directories unrelated
    # to a D/F replacement are deliberately left alone; Git does not track
    # directories and they are not required for correctness.
    protected def self.transition_directories(old_paths : Enumerable(String), new_paths : Enumerable(String)) : Array(String)
      old_dirs = path_prefixes(old_paths)
      targets = new_paths.to_a
      old_dirs.select do |directory|
        targets.any? { |path| directory == path || directory.starts_with?(path + "/") }
      end.to_a.sort_by { |path| {-path.count('/'), -path.bytesize, path} }
    end

    protected def self.transition_blocker?(removed : String, written : String) : Bool
      written.starts_with?(removed + "/") || removed.starts_with?(written + "/")
    end

    # A clean tracked regular file is read with the existing bounded,
    # identity-checked worktree reader. Missing files and mode changes refuse.
    protected def self.require_clean!(repository : Repository, index : Array(Index::Entry), *,
                                      max_blob_bytes : Int32, max_total_bytes : Int64,
                                      check : Proc(Nil)?, allow_symlinks : Bool = false,
                                      conversion : Conversion? = nil) : Hash(String, FileState)
      observed = {} of String => FileState
      scanned = 0_i64
      index.each do |entry|
        check.try &.call
        raise Error.new("Git checkout requires a fully merged, ordinary index") unless entry.stage == 0 && !entry.intent &&
                                                                                       !entry.skip_worktree && !entry.assume_unchanged &&
                                                                                       ({"100644", "100755"}.includes?(entry.mode) ||
                                                                                       (allow_symlinks && entry.mode == "120000"))
        mode, raw = if entry.mode == "120000"
                      {"120000", symlink_target(repository.root, entry.path, max_blob_bytes)}
                    else
                      repository.checkout_working_regular(entry.path, max_blob_bytes) { check.try &.call }
                    end
        scanned += raw.bytesize
        raise Error.new("Git checkout worktree scan budget exceeded") if scanned > max_total_bytes
        raw_oid = ObjectId.digest("blob", raw, repository.object_format)
        observed[entry.path] = FileState.new(mode, raw_oid)
        canonical = if conversion && entry.mode != "120000"
                      conversion.clean(entry.path, raw, index_oid: entry.oid)
                    else
                      raw
                    end
        oid = canonical == raw ? raw_oid : ObjectId.digest("blob", canonical, repository.object_format)
        raise Error.new("Git checkout refuses dirty tracked files") unless mode == entry.mode && oid == entry.oid
      end
      observed
    end
  end
end
