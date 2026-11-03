module Git
  struct Merge
    private def self.rename_identity(state : Checkout::FileState) : {String, String}
      kind = {"100644", "100755"}.includes?(state.mode) ? "regular" : state.mode
      {kind, state.oid}
    end

    # Conservative exact-content renames only: one unique base file removed
    # on a side, paired with one new path carrying the same blob OID and file
    # kind. Regular executable-bit changes may accompany the move. No content
    # similarity, copy or directory rename guesses are made.
    protected def self.exact_renames(base : Hash(String, Checkout::FileState),
                                     side : Hash(String, Checkout::FileState)) : Hash(String, String)
      base_counts = Hash({String, String}, Int32).new(0)
      base.each_value { |state| base_counts[rename_identity(state)] += 1 }
      added = {} of {String, String} => Array(String)
      side.each do |path, state|
        next if base.has_key?(path)
        key = rename_identity(state)
        (added[key] ||= [] of String) << path
      end
      moves = {} of String => String
      base.each do |path, state|
        key = rename_identity(state)
        next if side.has_key?(path) || base_counts[key] != 1
        targets = added[key]?
        moves[path] = targets.first if targets && targets.size == 1
      end
      moves
    end

    private def self.rename_with_other_change(base : Checkout::FileState,
                                              moved : Checkout::FileState,
                                              changed : Checkout::FileState) : Checkout::FileState
      return changed unless {base.mode, moved.mode, changed.mode}.all? { |mode| {"100644", "100755"}.includes?(mode) }
      mode = if moved.mode == changed.mode || changed.mode == base.mode
               moved.mode
             elsif moved.mode == base.mode
               changed.mode
             else
               changed.mode
             end
      Checkout::FileState.new(mode, changed.oid)
    end

    # :nodoc:
    # Reconcile one-sided exact renames with changes to the original path.
    # The destination stage-1 entry must retain the old base even though the
    # path did not exist in that base; a rename/delete or rename/type-change
    # is a conflict, never an unrelated addition that silently wins.
    record RenamePlan, resolutions : Hash(String, Checkout::FileState?),
      conflicts : Hash(String, Conflict)

    private def self.kind_changed?(before : Checkout::FileState,
                                   after : Checkout::FileState) : Bool
      rename_identity(before)[0] != rename_identity(after)[0]
    end

    protected def self.rename_plan(base : Hash(String, Checkout::FileState),
                                   ours : Hash(String, Checkout::FileState),
                                   theirs : Hash(String, Checkout::FileState)) : RenamePlan
      our_moves = exact_renames(base, ours)
      their_moves = exact_renames(base, theirs)
      resolutions = {} of String => Checkout::FileState?
      conflicts = {} of String => Conflict
      our_moves.each do |old, dest|
        if other_dest = their_moves[old]?
          raise Git::Error.new("Git merge rename/rename divergent destinations unsupported") unless other_dest == dest
          next
        end
        next if theirs.has_key?(dest) # Existing destination: ordinary add/add conflict.
        if changed = theirs[old]?
          next if changed == base[old]
          if kind_changed?(base[old], changed)
            # Git retains the changed original path as stage zero and the
            # rename destination as stages 1/2 (ours) or 1/3 (theirs).
            resolutions[old] = changed
            conflicts[dest] = Conflict.new(dest, base[old], ours[dest], nil)
          else
            resolutions[old] = nil
            resolutions[dest] = rename_with_other_change(base[old], ours[dest], changed)
          end
        else
          conflicts[dest] = Conflict.new(dest, base[old], ours[dest], nil)
        end
      end
      their_moves.each do |old, dest|
        next if our_moves.has_key?(old)
        next if ours.has_key?(dest) # Existing destination: ordinary add/add conflict.
        if changed = ours[old]?
          next if changed == base[old]
          raise Git::Error.new("Git merge ambiguous exact rename") if resolutions.has_key?(old) || resolutions.has_key?(dest)
          if kind_changed?(base[old], changed)
            resolutions[old] = changed
            conflicts[dest] = Conflict.new(dest, base[old], nil, theirs[dest])
          else
            resolutions[old] = nil
            resolutions[dest] = rename_with_other_change(base[old], theirs[dest], changed)
          end
        else
          conflicts[dest] = Conflict.new(dest, base[old], nil, theirs[dest])
        end
      end
      RenamePlan.new(resolutions, conflicts)
    end
  end
end
