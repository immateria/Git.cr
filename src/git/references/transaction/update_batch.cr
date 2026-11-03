module Git
  module References
    class Transaction
      # target lock in stable order, validate all expected OIDs, and fsync all
      # lock contents before publishing any ref. Conflicts/cancellation during
      # preparation leave refs unchanged. Like Git's loose-files backend,
      # distinct final renames and reflog appends are NOT one crash-atomic
      # filesystem operation; a late I/O error can partially publish a batch.
      def self.update_many(metadata : Metadata, format : ObjectId::Format,
                           changes : Array(Update), *, max_updates : Int32 = 64,
                           check : Proc(Nil)? = nil) : Nil
        raise ArgumentError.new("invalid Git reference transaction budget") if max_updates < 1
        raise Error.new("Git reference transaction must not be empty") if changes.empty?
        raise Error.new("Git reference transaction budget exceeded") if changes.size > max_updates
        ordered = changes.sort_by(&.name)
        previous_name = ""
        ordered.each do |change|
          raise Error.new("unsupported Git reference scope") unless change.name.starts_with?("refs/")
          RefName.valid!(change.name)
          metadata.require_reference_namespace!(change.name)
          ObjectId.valid!(change.new_oid, format)
          if expected = change.expected_oid
            ObjectId.valid!(expected, format)
          end
          change.log.try(&.encode(change.expected_oid || "0" * format.hexsize, change.new_oid))
          if !previous_name.empty? && (change.name == previous_name || change.name.starts_with?(previous_name + "/"))
            raise Error.new("overlapping Git transaction references")
          end
          previous_name = change.name
        end
        metadata.check!
        locks = [] of {Update, String, String, String, IO::FileDescriptor}
        owned_locks = Set(String).new
        begin
          ordered.each do |change|
            check.try &.call
            local = change.name.starts_with?("refs/worktree/") || change.name.starts_with?("refs/bisect/") ||
                    change.name.starts_with?("refs/rewritten/")
            base = local ? metadata.git_dir : metadata.common
            directory = base
            change.name.split('/')[0...-1].each do |component|
              directory = File.join(directory, component)
              ensure_real_directory!(directory)
            end
            target = File.join(base, change.name)
            raise Error.new("Git ref path redirected") if File.symlink?(target)
            lock = target + ".lock"
            fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o666)
            raise Error.new("Git ref lock unavailable") if fd < 0
            locks << {change, target, lock, directory, IO::FileDescriptor.new(fd)}
            owned_locks.add(lock)
          end
          metadata.check!
          # Holding all .lock files means cooperating Git writers cannot
          # modify any target between validation and its publication.
          locks.each do |change, target, _lock, _directory, io|
            check.try &.call
            current = metadata.resolve_ref?(change.name)
            raise Error.new("Git ref compare-and-swap mismatch") unless current == change.expected_oid
            raise Error.new("Git ref path redirected") if File.symlink?(target) || Dir.exists?(target)
            metadata.require_reference_namespace!(change.name)
            if File.file?(target)
              raise Error.new("symbolic Git reference mutation unsupported") if read_small_ref(target).starts_with?("ref: ")
            end
            io.write("#{change.new_oid}\n".to_slice)
            io.flush
            io.fsync
          end
          check.try &.call
          metadata.check!
          # Prepare reflogs before publication for parity with the existing
          # single-ref writer. Appends are not rollbackable on a late failure.
          attached, _ = metadata.head
          locks.each do |change, _target, _lock, _directory, _io|
            if log = change.log
              old = change.expected_oid || "0" * format.hexsize
              local = change.name.starts_with?("refs/worktree/") || change.name.starts_with?("refs/bisect/") ||
                      change.name.starts_with?("refs/rewritten/")
              base = local ? metadata.git_dir : metadata.common
              line = log.encode(old, change.new_oid)
              append_log(base, change.name, line)
              append_log(metadata.git_dir, "HEAD", line) if attached == change.name
            end
          end
          # File renames are individually atomic. Readers may observe an
          # intermediate state and a late error can publish a prefix only.
          directories = Set(String).new
          locks.each do |_change, target, lock, directory, io|
            io.close
            File.rename(lock, target)
            owned_locks.delete(lock) # another writer may now own this lock name
            directories.add(directory)
          end
          directories.each { |directory| File.open(directory) { |dir| dir.fsync } }
        ensure
          locks.each do |_change, _target, _lock, _directory, io|
            io.close unless io.closed?
          end
          owned_locks.each { |lock| File.delete?(lock) }
        end
      rescue ex : File::Error | IO::Error
        raise Error.new("Git reference transaction failed: #{ex.class}")
      end

      # A bounded mixed batch of direct ref updates and deletes. All target
      # locks (and the shared packed-refs lock for deletions) are held while
      # verifying EVERY expected OID. The packed replacement and update lock
      # files are prepared and synced before the first publication.
    end
  end
end
