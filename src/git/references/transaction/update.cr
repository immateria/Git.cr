module Git
  struct References
    # :nodoc:
    class Transaction
      # expected_oid: nil means the reference MUST NOT exist. Callers must
      # supply an exact old value for updates. The .lock serializes cooperating
      # Git writers and File.rename publishes a complete new ref atomically.
      # Optional reflog lines are appended while the ref lock is held, BEFORE
      # the ref rename. Like Git's loose-file backend this is not a cross-file
      # atomic transaction: a late failure may leave a reflog entry.
      def self.update(metadata : Metadata, format : ObjectId::Format,
                      name : String, new_oid : String, expected_oid : String?, *,
                      log : LogEntry? = nil, check : Proc(Nil)? = nil) : Nil
        raise Error.new("unsupported Git reference scope") unless name.starts_with?("refs/")
        RefName.valid!(name)
        metadata.require_reference_namespace!(name)
        ObjectId.valid!(new_oid, format)
        ObjectId.valid!(expected_oid, format) if expected_oid
        log.try(&.encode(expected_oid || "0" * format.hexsize, new_oid))
        metadata.check!
        local = name.starts_with?("refs/worktree/") || name.starts_with?("refs/bisect/") ||
                name.starts_with?("refs/rewritten/")
        base = local ? metadata.git_dir : metadata.common
        parts = name.split('/')
        directory = base
        parts[0...-1].each do |component|
          directory = File.join(directory, component)
          ensure_real_directory!(directory)
        end
        target = File.join(base, name)
        raise Error.new("Git ref path redirected") if File.symlink?(target) || Dir.exists?(target)
        dir = DescriptorPath::Directory.open(directory)
        begin
          leaf = parts.last
          lock_leaf = leaf + ".lock"
          io = dir.open_file(lock_leaf, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
          owned = true
          begin
            metadata.check!
            check.try &.call
            current = metadata.resolve_ref?(name)
            raise Error.new("Git ref compare-and-swap mismatch") unless current == expected_oid
            raise Error.new("Git ref path redirected") if File.symlink?(target) || Dir.exists?(target)
            if File.file?(target)
              raw = read_small_ref(target)
              raise Error.new("symbolic Git reference mutation unsupported") if raw.starts_with?("ref: ")
            end
            io.write("#{new_oid}\n".to_slice)
            io.flush
            io.fsync
            metadata.check!
            check.try &.call
            if log
              append_log(base, name, log.encode(expected_oid || "0" * format.hexsize, new_oid))
              attached, _ = metadata.head
              if attached == name
                append_log(metadata.git_dir, "HEAD", log.encode(expected_oid || "0" * format.hexsize, new_oid))
              end
            end
            # The open parent survives an attacker renaming the path tree;
            # publish into that directory, never a replacement symlink.
            raise Error.new("Git ref parent replaced during publication") unless dir.attached_at?(directory)
            dir.rename(lock_leaf, leaf)
            owned = false
            dir.sync
          ensure
            if owned && dir.same_inode?(lock_leaf, io)
              dir.unlink(lock_leaf)
              dir.sync
            end
            io.close unless io.closed?
          end
        ensure
          dir.close
        end
      rescue ex : File::Error | IO::Error
        raise Error.new("Git ref write failed: #{ex.class}")
      end
    end
  end
end
