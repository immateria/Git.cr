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
      magic = "\0git-replay-raw-v1\0"
      raise Error.new("Git replay recovery entry budget exceeded") if predecessor.size > max_entries || target.size > max_entries
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
      expected = magic + fields.join('\0')
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
  end
end
