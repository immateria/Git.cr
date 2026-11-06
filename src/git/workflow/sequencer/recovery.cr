module Git
  class Repository
    # Bind exact restoration identities before the first worktree mutation.
    # A retry may verify these identities but cannot select new ownership by
    # changing conversion configuration or attribute sources.
    private def replay_recovery!(directory : DescriptorPath::Directory, name : String,
                                 identity : String,
                                 predecessor : Hash(String, Checkout::FileState),
                                 target : Hash(String, Checkout::FileState), *,
                                 max_bytes : Int32, max_entries : Int32, persist : Bool = true) : String
      records = predecessor.size.to_i64 + target.size.to_i64
      paths = predecessor.keys.to_set | target.keys.to_set
      raise Error.new("Git replay recovery entry budget exceeded") if max_entries < 0 ||
                                                                      paths.size > max_entries || records > max_entries.to_i64 * 2
      fields = [identity, predecessor.size.to_s, target.size.to_s]
      {predecessor, target}.each do |states|
        states.keys.sort.each do |path|
          state = states[path]
          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
          raise Error.new("Git replay recovery mode invalid") unless {"100644", "100755", "120000"}.includes?(state.mode)
          ObjectId.valid!(state.oid, @object_format)
          fields.concat([path, state.mode, state.oid])
        end
      end
      expected = Sequencer::RAW_RECOVERY_MAGIC + fields.join('\0')
      raise Error.new("Git replay recovery byte budget exceeded") if expected.bytesize > max_bytes
      existing = Merge::Recovery.read(directory, name, max_bytes)
      required = Merge::Recovery.read(directory, "#{name}.required", 128)
      raise Error.new("Git required replay restoration metadata missing") if required && !existing
      raise Error.new("Git replay restoration marker invalid") if required && required != "raw-v1\n"
      raise Error.new("Git replay restoration identities changed") if existing && existing != expected
      return expected unless persist
      unless existing
        lock_name = "#{name}.lock"
        lock = directory.open_file(lock_name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        begin
          lock.write(expected.to_slice)
          lock.flush
          lock.fsync
          raise Error.new("Git replay recovery metadata appeared") if directory.stat?(name)
          directory.rename(lock_name, name)
          directory.sync
        ensure
          directory.unlink(lock_name) if directory.same_inode?(lock_name, lock)
          lock.close unless lock.closed?
        end
      end
      unless required
        marker = directory.open_file("#{name}.required", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        begin
          marker.write("raw-v1\n".to_slice)
          marker.flush
          marker.fsync
        ensure
          marker.close unless marker.closed?
        end
        directory.sync
      end
      expected
    end

    private def replay_require_recovery!(directory : DescriptorPath::Directory, name : String) : Nil
      io = directory.open_file?(name, LibC::O_RDONLY | LibC::O_NONBLOCK) ||
           raise Error.new("Git required replay restoration metadata missing")
      begin
        raise Error.new("Git replay restoration metadata not regular") unless io.info.type.file?
        prefix = Bytes.new(Sequencer::RAW_RECOVERY_MAGIC.bytesize)
        unless io.read_fully?(prefix) && prefix == Sequencer::RAW_RECOVERY_MAGIC.to_slice
          raise Error.new("Git required replay restoration metadata invalid")
        end
      ensure
        io.close unless io.closed?
      end
    end

    # The core operation record survives loss of both receipt-side files.
    private def replay_replace_metadata!(directory : DescriptorPath::Directory, name : String,
                                         before : String, after : String) : Nil
      return if before == after
      lock_name = "#{name}.lock"
      lock = directory.open_file(lock_name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
      begin
        lock.write(after.to_slice)
        lock.flush
        lock.fsync
        raise Error.new("Git replay operation metadata changed") unless Merge::Recovery.read(directory, name, 65_536) == before
        directory.rename(lock_name, name)
        directory.sync
      ensure
        directory.unlink(lock_name) if directory.same_inode?(lock_name, lock)
        lock.close unless lock.closed?
      end
    end
  end
end
