module Git
  class Repository
    # Newest-first stash stack, reconstructed from refs/stash's Git reflog.
    protected def stash_list(*, limit : Int32 = 100, max_log_bytes : Int32 = 8_388_608,
                             max_object_bytes : Int32 = 8_388_608,
                             max_entries : Int32 = 10_000,
                             check : Proc(Nil)? = nil) : Array(Stash::Entry)
      raise ArgumentError.new("invalid Git stash list budgets") if limit < 0 || max_log_bytes < 128 ||
                                                                   max_object_bytes < 128 || max_entries < 1
      records = stash_log_records(max_log_bytes: max_log_bytes, max_entries: max_entries,
        max_object_bytes: max_object_bytes, check: check)
      count = {limit, records.size}.min
      result = [] of Stash::Entry
      count.times do |position|
        record = records[records.size - 1 - position]
        result << stash_entry_from_record(position, record,
          max_object_bytes: max_object_bytes, check: check)
      end
      result
    end

    protected def stash_show(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
                             max_object_bytes : Int32 = 8_388_608,
                             max_entries : Int32 = 10_000,
                             check : Proc(Nil)? = nil) : Stash::Entry
      raise ArgumentError.new("invalid Git stash position") if position < 0
      records = stash_log_records(max_log_bytes: max_log_bytes, max_entries: max_entries,
        max_object_bytes: max_object_bytes, check: check)
      raise Error.new("Git stash entry not found") if position >= records.size
      record = records[records.size - 1 - position]
      stash_entry_from_record(position, record, max_object_bytes: max_object_bytes, check: check)
    end
  end
end
