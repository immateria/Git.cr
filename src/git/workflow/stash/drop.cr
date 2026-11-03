module Git
  class Repository
    # Drop any stash position while preserving Git's reflog stack semantics.
    # Middle-entry removal rechains subsequent reflog old-OIDs exactly as Git
    # does. Top removal moves refs/stash to the previous entry; final removal
    # deletes the ref and its reflog through the native ref transaction.
    protected def stash_drop(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
                             max_object_bytes : Int32 = 8_388_608,
                             max_entries : Int32 = 10_000,
                             check : Proc(Nil)? = nil) : Stash::Entry
      raise ArgumentError.new("invalid Git stash position") if position < 0
      records = stash_log_records(max_log_bytes: max_log_bytes, max_entries: max_entries,
        max_object_bytes: max_object_bytes, check: check)
      raise Error.new("Git stash entry not found") if position >= records.size
      raw = stash_log_raw?(max_log_bytes) || raise Error.new("Git stash reflog missing")
      array_index = records.size - 1 - position
      dropped_record = records[array_index]
      dropped = stash_entry_from_record(position, dropped_record,
        max_object_bytes: max_object_bytes, check: check)
      top = records.last.new_oid
      if records.size == 1
        delete_ref(Stash::REF, expected_oid: top, check: check)
        return dropped
      end
      remaining = records.dup
      remaining.delete_at(array_index)
      remaining = stash_rechain(remaining)
      if position == 0
        new_top = remaining.last.new_oid
        ref_published = false
        begin
          update_ref(Stash::REF, new_top, expected_oid: top,
            max_object_bytes: max_object_bytes, check: check)
          ref_published = true
          stash_rewrite_log!(remaining, expected_ref: new_top,
            expected_raw: raw, max_log_bytes: max_log_bytes, check: check)
        rescue ex
          raise Stash::PartialDrop.new(dropped.oid, ref_published, ex)
        end
      else
        begin
          stash_rewrite_log!(remaining, expected_ref: top,
            expected_raw: raw, max_log_bytes: max_log_bytes, check: check)
        rescue ex
          raise Stash::PartialDrop.new(dropped.oid, false, ex)
        end
      end
      dropped
    end
  end
end
