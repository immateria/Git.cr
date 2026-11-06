module Git
  struct Merge
    private def self.rename_identity(state : Checkout::FileState) : {String, String}
      kind = {"100644", "100755"}.includes?(state.mode) ? "regular" : state.mode
      {kind, state.oid}
    end

    # Conservative exact-content renames only: one unique base file removed
    # on a side, paired with one new path carrying the same blob OID and file
    # kind. Regular executable-bit changes may accompany the move. This exact phase precedes
    # bounded regular-file similarity matching; it does not detect copies or
    # directory renames.
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

    # :nodoc:
    record MarkerContext, ours : String, theirs : String, size : Int32

    # :nodoc:
    # Reconcile detected renames with changes to the original path. Conflict
    # stages preserve their logical source; destination collisions also carry
    # the outer marker context independently of their nested source blobs.
    record RenamePlan, resolutions : Hash(String, Checkout::FileState?),
      conflicts : Hash(String, Conflict),
      markers : Hash(String, MarkerContext) = {} of String => MarkerContext,
      structural_collisions : Set(String) = Set(String).new

    private def self.kind_changed?(before : Checkout::FileState,
                                   after : Checkout::FileState) : Bool
      rename_identity(before)[0] != rename_identity(after)[0]
    end

    protected def self.rename_plan(repository : Repository, base : Hash(String, Checkout::FileState),
                                   ours : Hash(String, Checkout::FileState),
                                   theirs : Hash(String, Checkout::FileState), *,
                                   max_object_bytes : Int32, max_total_bytes : Int64,
                                   check : Proc(Nil)?, their_label : String = "MERGE_HEAD",
                                   our_label : String = "HEAD", marker_size : Int32 = 7,
                                   virtual : Bool = false) : RenamePlan
      similarity = Similarity.new(repository, max_object_bytes, max_total_bytes, check)
      our_moves = similarity.find(base, ours, exact_renames(base, ours), theirs)
      their_moves = similarity.find(base, theirs, exact_renames(base, theirs), ours)
      resolutions = {} of String => Checkout::FileState?
      conflicts = {} of String => Conflict
      contexts = {} of String => MarkerContext
      structural = Set(String).new
      our_moves.each do |old, dest|
        if other_dest = their_moves[old]?
          if other_dest == dest
            resolutions[old] = nil
            if ours[dest] == theirs[dest]
              resolutions[dest] = ours[dest]
            else
              conflicts[dest] = Conflict.new(dest, base[old], ours[dest], theirs[dest])
            end
          else
            merged = merge_blob(repository, base[old], ours[dest], theirs[other_dest], max_object_bytes, check)
            shared = if merged
                       merged[0]
                     elsif marker = markers(repository, ours[dest], theirs[other_dest],
                             "#{their_label}:#{other_dest}", max_object_bytes, check,
                             ours_label: "#{our_label}:#{dest}", marker_size: marker_size + 1)
                       Checkout::FileState.new(ours[dest].mode, repository.write_blob(marker, max_bytes: max_object_bytes, check: check))
                     else
                       nil
                     end
            # A binary conflict has no merged blob: retain each destination's
            # own bytes rather than copying ours over the incoming rename.
            conflicts[old] = Conflict.new(old, base[old], nil, nil)
            conflicts[dest] = Conflict.new(dest, nil, shared || ours[dest], nil)
            conflicts[other_dest] = Conflict.new(other_dest, nil, nil, shared || theirs[other_dest])
          end
          next
        end
        if addition = theirs[dest]?
          contexts[dest] = MarkerContext.new(our_label, their_label, marker_size)
          if changed = theirs[old]?
            merged = merge_collision_source(repository, base[old], ours[dest], changed,
              our_label: "#{our_label}:#{dest}", their_label: "#{their_label}:#{old}",
              marker_size: marker_size, virtual: virtual,
              max_object_bytes: max_object_bytes, check: check)
            resolutions[old] = nil
            conflicts[dest] = Conflict.new(dest, nil, merged, addition)
          else
            structural.add(dest)
          end
          next
        end
        if changed = theirs[old]?
          next if changed == base[old]
          if kind_changed?(base[old], changed)
            # Git retains the changed original path as stage zero and the
            # rename destination as stages 1/2 (ours) or 1/3 (theirs).
            resolutions[old] = changed
            conflicts[dest] = Conflict.new(dest, base[old], ours[dest], nil)
          else
            resolutions[old] = nil
            if ours[dest].mode == "120000"
              resolutions[dest] = changed
            else
              conflicts[dest] = Conflict.new(dest, base[old], ours[dest], changed)
            end
          end
        else
          conflicts[dest] = Conflict.new(dest, base[old], ours[dest], nil)
        end
      end
      their_moves.each do |old, dest|
        next if our_moves.has_key?(old)
        if addition = ours[dest]?
          contexts[dest] = MarkerContext.new(our_label, their_label, marker_size)
          # Compose both source contributions when two renames collide.
          addition = conflicts[dest]?.try(&.ours) || addition
          if changed = ours[old]?
            merged = merge_collision_source(repository, base[old], changed, theirs[dest],
              our_label: "#{our_label}:#{old}", their_label: "#{their_label}:#{dest}",
              marker_size: marker_size, virtual: virtual,
              max_object_bytes: max_object_bytes, check: check)
            resolutions[old] = nil
            conflicts[dest] = Conflict.new(dest, nil, addition, merged)
          else
            structural.add(dest)
          end
          next
        end
        if changed = ours[old]?
          next if changed == base[old]
          raise Git::Error.new("Git merge ambiguous exact rename") if resolutions.has_key?(old) || resolutions.has_key?(dest)
          if kind_changed?(base[old], changed)
            resolutions[old] = changed
            conflicts[dest] = Conflict.new(dest, base[old], nil, theirs[dest])
          else
            resolutions[old] = nil
            if theirs[dest].mode == "120000"
              resolutions[dest] = changed
            else
              conflicts[dest] = Conflict.new(dest, base[old], changed, theirs[dest])
            end
          end
        else
          conflicts[dest] = Conflict.new(dest, base[old], nil, theirs[dest])
        end
      end
      RenamePlan.new(resolutions, conflicts, contexts, structural)
    end
  end
end
