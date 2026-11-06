module Git
  struct Merge
    # Render only the worktree aid with the chosen regular mode; real index
    # stages retain their distinct executable bits. Equal OIDs need no markers
    # even when a mode-only or structural conflict keeps the stages unmerged.
    private def self.collision_markers(repository : Repository, ours : Checkout::FileState?,
                                       theirs : Checkout::FileState?, context : MarkerContext,
                                       max_bytes : Int32, check : Proc(Nil)?) : String?
      check.try &.call
      return nil unless ours && theirs && {ours.mode, theirs.mode}.all? { |mode| {"100644", "100755"}.includes?(mode) }
      return nil if ours.oid == theirs.oid
      contents = {ours, theirs}.map do |state|
        kind, raw = repository.object(state.oid, max_bytes) { check.try &.call }
        raise Error.new("Git rename collision target is not a blob") unless kind == "blob"
        raw
      end
      return nil if contents.any?(&.includes?('\0'))
      raise Error.new("Git rename/add destination conflict text encoding unsupported") unless contents.all?(&.valid_encoding?)
      marker = markers(repository, ours, Checkout::FileState.new(ours.mode, theirs.oid),
        context.theirs, max_bytes, check, ours_label: context.ours,
        marker_size: context.size, allow_missing_newline: true)
      raise Error.new("Git rename/add destination conflict marker budget exceeded") unless marker
      marker
    end

    # Source content is merged before the destination's add/add collision.
    # Even an unresolved source contributes a real blob: text markers nest
    # one level deeper; binary content follows Git's side/ancestor selection.
    private def self.merge_collision_source(repository : Repository,
                                            base : Checkout::FileState,
                                            ours : Checkout::FileState,
                                            theirs : Checkout::FileState, *,
                                            our_label : String, their_label : String,
                                            marker_size : Int32, virtual : Bool,
                                            max_object_bytes : Int32,
                                            check : Proc(Nil)?) : Checkout::FileState
      check.try &.call
      if kind_changed?(base, ours) || kind_changed?(base, theirs)
        raise Error.new("Git rename/add with differing source types unsupported")
      end
      mode = ours.mode == theirs.mode || ours.mode == base.mode ? theirs.mode : ours.mode
      oid = if ours.oid == theirs.oid || ours.oid == base.oid
              theirs.oid
            elsif theirs.oid == base.oid
              ours.oid
            end
      return Checkout::FileState.new(mode, oid) if oid
      if merged = merge_blob(repository, base, ours, theirs, max_object_bytes, check)
        return merged[0]
      end
      return virtual ? base : Checkout::FileState.new(mode, ours.oid) if mode == "120000"
      contents = {base, ours, theirs}.map do |state|
        kind, raw = repository.object(state.oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git rename collision source is not a blob") unless kind == "blob"
        raw
      end
      if contents.any?(&.includes?('\0'))
        return Checkout::FileState.new(mode, virtual ? base.oid : ours.oid)
      end
      unless contents.all?(&.valid_encoding?)
        raise Error.new("Git rename/add source conflict text encoding unsupported")
      end
      marker = markers(repository, Checkout::FileState.new(mode, ours.oid),
        Checkout::FileState.new(mode, theirs.oid), their_label, max_object_bytes, check,
        ours_label: our_label, marker_size: marker_size + 1, allow_missing_newline: true)
      raise Error.new("Git rename/add source conflict marker budget exceeded") unless marker
      oid = repository.write_blob(marker, max_bytes: max_object_bytes, check: check)
      Checkout::FileState.new(mode, oid)
    end
  end
end
