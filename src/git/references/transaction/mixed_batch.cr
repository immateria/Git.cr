module Git
  struct References
    # :nodoc:
    class Transaction
      #
      # Git's files backend does not provide cross-file atomic renames. Failed
      # preparation leaves ref values unchanged; post-publication failures
      # surface PartialPublication with known effects, never false rollback.
      def self.change_many(metadata : Metadata, format : ObjectId::Format,
                           changes : Array(Change), *, max_changes : Int32 = 64,
                           max_packed_bytes : Int32 = 8_388_608,
                           check : Proc(Nil)? = nil,
                           after_publish : Proc(String, Nil)? = nil) : Nil
        raise ArgumentError.new("invalid Git reference transaction budget") if max_changes < 1
        raise ArgumentError.new("invalid packed Git reference budget") if max_packed_bytes < 128
        raise Error.new("Git reference transaction must not be empty") if changes.empty?
        raise Error.new("Git reference transaction budget exceeded") if changes.size > max_changes
        ordered = changes.sort_by(&.name)
        previous_name = ""
        to_delete = Set(String).new
        ordered.each do |change|
          name = change.name
          raise Error.new("unsupported Git reference scope") unless name.starts_with?("refs/")
          RefName.valid!(name)
          if !previous_name.empty? && (name == previous_name || name.starts_with?(previous_name + "/"))
            raise Error.new("overlapping Git transaction references")
          end
          previous_name = name
          if expected = change.expected_oid
            ObjectId.valid!(expected, format)
          end
          case change
          when Update
            ObjectId.valid!(change.new_oid, format)
            change.log.try(&.encode(change.expected_oid || "0" * format.hexsize, change.new_oid))
          when Delete
            to_delete.add(name)
          end
        end
        metadata.check!
        # A ref lock is owned only until it is renamed to its target. Once
        # published, its path can be reacquired by another process.
        locks = [] of {Change, String, String, String, String, IO::FileDescriptor}
        owned_locks = Set(String).new
        packed_lock = File.join(metadata.common, "packed-refs.lock")
        packed_path = File.join(metadata.common, "packed-refs")
        packed_io = nil.as(IO::FileDescriptor?)
        packed_dir = nil.as(DescriptorPath::Directory?)
        pinned_dirs = {} of String => DescriptorPath::Directory
        own_packed_lock = false
        packed_published = false
        reflogs_started = false
        published = [] of String
        begin
          ordered.each do |change|
            check.try &.call
            name = change.name
            local = name.starts_with?("refs/worktree/") || name.starts_with?("refs/bisect/") ||
                    name.starts_with?("refs/rewritten/")
            base = local ? metadata.git_dir : metadata.common
            directory = base
            name.split('/')[0...-1].each do |component|
              directory = File.join(directory, component)
              ensure_real_directory!(directory)
            end
            target = File.join(base, name)
            raise Error.new("Git ref path redirected") if File.symlink?(target) || Dir.exists?(target)
            lock = target + ".lock"
            dir = pinned_dirs[directory]? || begin
              opened = DescriptorPath::Directory.open(directory)
              pinned_dirs[directory] = opened
              opened
            end
            leaf = File.basename(lock)
            io = dir.open_file(leaf, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
            locks << {change, base, target, lock, directory, io}
            owned_locks.add(lock)
          end
          if !to_delete.empty?
            check.try &.call
            packed_dir = DescriptorPath::Directory.open(metadata.common)
            begin
              packed_io = packed_dir.not_nil!.open_file("packed-refs.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
            rescue Git::Error
              raise Error.new("Git packed-ref lock unavailable")
            end
            own_packed_lock = true
          end
          metadata.check!
          check.try &.call
          # Revalidate the namespace under the packed lock. New parents or
          # children of a ref being deleted remain unsupported in one batch.
          locks.each do |change, _base, target, _lock, directory, io|
            dir = pinned_dirs[directory]
            raise Error.new("Git ref parent replaced during preflight") unless dir.attached_at?(directory)
            # Inspect the leaf through the pinned directory, not a second
            # pathname traversal that could follow a swapped ancestor.
            if original = dir.open_file?(File.basename(target))
              begin
                raise Error.new("Git ref path redirected") unless original.info.type.file?
                raw = IO::Memory.new
                IO.copy(original, raw, 4097)
                raise Error.new("Git ref too large") if raw.size > 4096
                raise Error.new("symbolic Git reference mutation unsupported") if raw.to_s.starts_with?("ref: ")
              ensure
                original.close
              end
            end
            current = metadata.resolve_ref?(change.name)
            raise Error.new("Git ref compare-and-swap mismatch") unless current == change.expected_oid
            case change
            when Update
              metadata.require_reference_namespace!(change.name)
              io.write("#{change.new_oid}\n".to_slice)
              io.flush
              io.fsync
            when Delete
              reflog = File.join(_base, "logs", change.name)
              validate_optional_log!(reflog)
            end
          end
          packed_replacement = ""
          packed_found = Set(String).new
          if !to_delete.empty?
            raise Error.new("Git packed-ref parent replaced") unless packed_dir.not_nil!.attached_at?(metadata.common)
            raw = read_packed_from_directory?(packed_dir.not_nil!, max_packed_bytes)
            packed_replacement, packed_found = remove_packed_refs(raw, to_delete, format)
            locks.each do |change, _base, target, _lock, directory, _io|
              next unless change.is_a?(Delete)
              raise Error.new("Git reference disappeared") unless packed_found.includes?(change.name) || !!pinned_dirs[directory].stat?(File.basename(target))
            end
            if !packed_found.empty?
              io = packed_io.not_nil!
              io.write(packed_replacement.to_slice)
              io.flush
              io.fsync
            end
          end
          metadata.check!
          check.try &.call
          # Once logs begin, a late failure can leave observable side effects.
          # Do not invoke the caller's cancellation callback after this point.
          attached, _ = metadata.head
          locks.each do |change, base, _target, _lock, _dir, _io|
            next unless change.is_a?(Update)
            if log = change.log
              line = log.encode(change.expected_oid || "0" * format.hexsize, change.new_oid)
              reflogs_started = true
              append_log(base, change.name, line)
              append_log(metadata.git_dir, "HEAD", line) if attached == change.name
            end
          end
          # Drop packed entries first so a deleted loose override cannot
          # reveal its older packed value. Publish other refs while locks are
          # still owned; individual files remain independently visible.
          if !packed_found.empty?
            dir = packed_dir.not_nil!
            raise Error.new("Git packed-ref parent replaced during publication") unless dir.attached_at?(metadata.common)
            raise Error.new("Git packed-ref lock ownership changed") unless dir.same_inode?("packed-refs.lock", packed_io.not_nil!)
            dir.rename("packed-refs.lock", "packed-refs")
            own_packed_lock = false
            packed_published = true
            dir.sync
          end
          directories = Set(String).new
          locks.each do |change, base, target, lock, directory, io|
            dir = pinned_dirs[directory]
            raise Error.new("Git ref parent replaced during publication") unless dir.attached_at?(directory)
            raise Error.new("Git ref lock ownership changed") unless dir.same_inode?(File.basename(lock), io)
            case change
            when Update
              dir.rename(File.basename(lock), File.basename(target))
              owned_locks.delete(lock)
            when Delete
              if info = dir.stat?(File.basename(target))
                raise Error.new("Git ref path redirected") unless (info.st_mode & LibC::S_IFMT) == LibC::S_IFREG
                dir.unlink(File.basename(target))
              end
            end
            published << change.name
            directories.add(directory)
            # An opt-in observation hook runs only AFTER publication. It
            # cannot veto an operation without leaving partial state.
            after_publish.try &.call(change.name)
          end
          directories.each { |directory| pinned_dirs[directory].sync }
          # Deleted refs have no surviving reflog, including for packed-only
          # entries. HEAD is a different symbolic ref with its own log.
          locks.each do |change, base, _target, _lock, _dir, _io|
            next unless change.is_a?(Delete)
            reflog = File.join(base, "logs", change.name)
            File.delete(reflog) if File.file?(reflog)
          end
        rescue ex
          if packed_published || reflogs_started || !published.empty?
            raise PartialPublication.new(published.dup, packed_published, reflogs_started, ex)
          end
          case ex
          when File::Error, IO::Error
            raise Error.new("Git reference transaction failed: #{ex.class}")
          else
            raise ex
          end
        ensure
          if own_packed_lock && packed_dir && packed_io
            if packed_dir.same_inode?("packed-refs.lock", packed_io)
              packed_dir.unlink("packed-refs.lock")
              packed_dir.sync
            end
          end
          packed_io.try { |io| io.close unless io.closed? }
          packed_dir.try &.close
          locks.each do |_change, _base, _target, lock, directory, io|
            if owned_locks.includes?(lock) && pinned_dirs[directory].same_inode?(File.basename(lock), io)
              pinned_dirs[directory].unlink(File.basename(lock))
              pinned_dirs[directory].sync
            end
            io.close unless io.closed?
          end
          pinned_dirs.each_value(&.close)
        end
      end

      # Bounded packed-ref read relative to the same pinned common directory
    end
  end
end
