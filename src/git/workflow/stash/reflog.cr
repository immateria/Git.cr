module Git
  class Repository
    private def stash_entry_from_record(position : Int32, record : Stash::LogRecord, *,
                                        max_object_bytes : Int32,
                                        check : Proc(Nil)?) : Stash::Entry
      stored = commit(record.new_oid, max_object_bytes) { check.try &.call }
      raise Error.new("Git stash commit shape unsupported") unless stored.parents.size == 2 || stored.parents.size == 3
      base_oid = stored.parents[0]
      index_oid = stored.parents[1]
      index_commit = commit(index_oid, max_object_bytes) { check.try &.call }
      raise Error.new("Git stash index commit shape invalid") unless index_commit.parents == [base_oid]
      Stash::Entry.new(position, stored.oid, base_oid, index_oid, stored.tree,
        index_commit.tree, record.message, stored.parents[2]?)
    end

    private def stash_log_records(*, max_log_bytes : Int32, max_entries : Int32,
                                  max_object_bytes : Int32,
                                  check : Proc(Nil)?) : Array(Stash::LogRecord)
      check!
      current = resolve_ref?(Stash::REF)
      raw = stash_log_raw?(max_log_bytes)
      if current.nil?
        raise Error.new("Git stash reflog exists without refs/stash") if raw && !raw.empty?
        return [] of Stash::LogRecord
      end
      raise Error.new("Git stash reflog missing") unless raw
      records = stash_parse_log(raw, max_entries)
      raise Error.new("Git stash reflog empty") if records.empty?
      raise Error.new("Git stash reflog top does not match refs/stash") unless records.last.new_oid == current
      # Resolve the top commit now so a dangling/corrupt stack is rejected
      # before push/drop extends or rewrites it.
      commit(current, max_object_bytes) { check.try &.call }
      records
    end

    private def stash_log_raw?(max_bytes : Int32) : String?
      parent_path = File.join(@common, "logs", "refs")
      return nil unless Dir.exists?(parent_path) || File.symlink?(parent_path)
      dir = DescriptorPath::Directory.open(parent_path)
      begin
        io = dir.open_file?("stash")
        return nil unless io
        begin
          raise Error.new("Git stash reflog is not a regular file") unless io.info.type.file?
          raise Error.new("Git stash reflog byte budget exceeded") if io.info.size > max_bytes
          data = IO::Memory.new
          IO.copy(io, data, max_bytes.to_i64 + 1)
          raise Error.new("Git stash reflog byte budget exceeded") if data.size > max_bytes
          data.to_s
        ensure
          io.close unless io.closed?
        end
      ensure
        dir.close
      end
    end

    private def stash_parse_log(raw : String, max_entries : Int32) : Array(Stash::LogRecord)
      records = [] of Stash::LogRecord
      hex = @object_format.hexsize
      raw.each_line(chomp: false) do |line|
        raise Error.new("Git stash reflog entry budget exceeded") if records.size >= max_entries
        raise Error.new("Git stash reflog has incomplete line") unless line.ends_with?('\n')
        payload = line.byte_slice(0, line.bytesize - 1)
        payload = payload.byte_slice(0, payload.bytesize - 1) if payload.ends_with?('\r')
        raise Error.new("Git stash reflog line truncated") if payload.bytesize < hex * 2 + 3
        raise Error.new("Git stash reflog separator invalid") unless payload.byte_at(hex) == 32 && payload.byte_at(hex * 2 + 1) == 32
        old_oid = payload.byte_slice(0, hex)
        new_oid = payload.byte_slice(hex + 1, hex)
        zero = "0" * hex
        ObjectId.valid!(old_oid, @object_format) unless old_oid == zero
        ObjectId.valid!(new_oid, @object_format)
        tail = payload.byte_slice(hex * 2 + 2, payload.bytesize - hex * 2 - 2)
        delimiter = nil.as(Int32?)
        tail.bytesize.times do |offset|
          next unless tail.byte_at(offset) == 9
          begin
            Signature.parse_git_header(tail.byte_slice(0, offset))
            delimiter = offset
            break
          rescue Git::Error
          end
        end
        split = delimiter || raise Error.new("Git stash reflog identity invalid")
        identity = tail.byte_slice(0, split)
        message = tail.byte_slice(split + 1, tail.bytesize - split - 1)
        raise Error.new("Git stash reflog message invalid") if message.includes?('\0') || message.includes?('\n') || message.includes?('\r')
        records << Stash::LogRecord.new(old_oid, new_oid, identity, message)
      end
      records.each_cons(2) do |pair|
        raise Error.new("Git stash reflog chain invalid") unless pair[1].old_oid == pair[0].new_oid
      end
      records
    end

    private def stash_rechain(records : Array(Stash::LogRecord)) : Array(Stash::LogRecord)
      previous = "0" * @object_format.hexsize
      records.map do |record|
        next_record = Stash::LogRecord.new(previous, record.new_oid, record.identity, record.message)
        previous = record.new_oid
        next_record
      end
    end

    private def stash_rewrite_log!(records : Array(Stash::LogRecord), *,
                                   expected_ref : String, expected_raw : String,
                                   max_log_bytes : Int32,
                                   check : Proc(Nil)?) : Nil
      raise Error.new("Git stash reflog rewrite cannot publish empty stack") if records.empty?
      raw = String.build { |io| records.each { |record| io << record.encode } }
      raise Error.new("Git stash reflog byte budget exceeded") if raw.bytesize > max_log_bytes
      parent_path = File.join(@common, "logs", "refs")
      dir = DescriptorPath::Directory.open(parent_path)
      lock = nil.as(IO::FileDescriptor?)
      begin
        lock = dir.open_file("stash.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        lock.write(raw.to_slice)
        lock.flush
        lock.fsync
        check.try &.call
        raise Error.new("Git stash ref changed during reflog rewrite") unless resolve_ref?(Stash::REF) == expected_ref
        raise Error.new("Git stash reflog changed during rewrite") unless stash_log_raw?(max_log_bytes) == expected_raw
        raise Error.new("Git stash reflog parent replaced") unless dir.attached_at?(parent_path)
        dir.rename("stash.lock", "stash")
        dir.sync
        lock.close unless lock.closed?
        lock = nil
      ensure
        if io = lock
          if dir.same_inode?("stash.lock", io)
            dir.unlink("stash.lock")
            dir.sync
          end
          io.close unless io.closed?
        end
        dir.close
      end
    end
  end
end
