module Git
  struct References
    struct Recovery
      private def self.verify_published!(metadata : Metadata, changes : Array(Change),
                                         image : Index::Image?, index_store : Index?) : Nil
        raise Conflict.new("Git recovery incomplete: refs changed after publication") unless remaining_changes(metadata, changes).empty?
        if image
          raise Conflict.new("Git recovery incomplete: index changed after publication") unless index_store.not_nil!.image_state(image, max_bytes: MAX_INDEX_IMAGE_BYTES) == :desired
        end
      end

      # Finalize under the Git files-backend locks and publish a durable
      # ownership receipt BEFORE unlinking the redo. Once the redo is gone,
      # that receipt is the only authority for removing a killed finalizer's
      # orphan locks. A third party's unmarked/replaced lock is never removed.
      private def self.finalize_journal!(metadata : Metadata, directory : String, path : String,
                                         changes : Array(Change), image : Index::Image?,
                                         index_store : Index?, finalization_probe : Proc(Nil)? = nil,
                                         after_journal_unlink : Proc(Nil)? = nil,
                                         after_receipt_durable : Proc(Nil)? = nil,
                                         expected_redo : IO::FileDescriptor? = nil) : Nil
        locks = [] of {String, DescriptorPath::Directory, String, IO::FileDescriptor}
        receipt_path = File.join(directory, "#{File.basename(path).rchop(".redo")}.finish")
        journal_dir = DescriptorPath::Directory.open(directory)
        token = Random::Secure.hex(24)
        receipt_written = false
        redo_unlinked = false
        receipt_stat = nil.as(LibC::Stat?)
        begin
          paths = finalization_lock_paths(metadata, changes, !!image)
          paths.each do |lock_path|
            metadata.check!
            dir, name = DescriptorPath::Directory.open_parent(lock_path)
            begin
              io = dir.open_file(name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
            rescue
              dir.close
              raise Conflict.new("Git recovery finalization blocked by Git lock: #{lock_path}")
            end
            locks << {lock_path, dir, name, io}
            io.write(finalization_marker(token).to_slice)
            io.flush
            io.fsync
            dir.sync
          end
          metadata.check!
          # Low-level test seam only: can kill a process before receipt write.
          finalization_probe.try &.call
          verify_published!(metadata, changes, image, index_store)
          raise Conflict.new("Git finalization parent replaced") unless locks.all? do |lock_path, dir, _, _|
                                                                          dir.attached_at?(File.dirname(lock_path))
                                                                        end
          if expected_redo
            raise Conflict.new("Git recovery redo inode replaced") unless journal_dir.same_inode?(File.basename(path), expected_redo)
          end
          receipt = Finalization.new(token, checksum_file!(path, MAX_INDEX_JOURNAL_BYTES),
            changes.sort_by(&.name).map { |change| {change.name, change.is_a?(Update) ? change.new_oid : nil} },
            image ? Digest::SHA256.hexdigest(image.data) : nil)
          raise Conflict.new("Git recovery journal parent replaced") unless journal_dir.attached_at?(directory)
          write_finalization!(metadata, receipt_path, receipt, journal_dir)
          receipt_stat = journal_dir.stat?(File.basename(receipt_path))
          receipt_written = true
          after_receipt_durable.try &.call
          raise Conflict.new("Git recovery journal parent replaced") unless journal_dir.attached_at?(directory)
          if expected_redo
            raise Conflict.new("Git recovery redo inode replaced") unless journal_dir.same_inode?(File.basename(path), expected_redo)
          end
          journal_dir.unlink(File.basename(path))
          redo_unlinked = true
          journal_dir.sync
          # Low-level process-death test: the redo is gone, but the owned
          # Git locks and the durable receipt still exist.
          after_journal_unlink.try &.call
        ensure
          # Normal unwind still cleans only the exact inodes we created.
          # If cleanup is interrupted or a path is replaced, the receipt
          # remains for explicit inspection/recovery after process death.
          locks.reverse_each do |lock_path, dir, name, io|
            begin
              # The parent is pinned. A renamed parent/symlink can never
              # redirect cleanup to a different directory's lock file.
              if dir.same_inode?(name, io)
                dir.unlink(name)
                dir.sync
              end
            ensure
              io.close unless io.closed?
              dir.close
            end
          end
          if receipt_written && redo_unlinked && finalization_lock_paths(metadata, changes, !!image).all? { |lock_path| !File.exists?(lock_path) && !File.symlink?(lock_path) }
            if journal_dir.attached_at?(directory) && (original = receipt_stat) && (current = journal_dir.stat?(File.basename(receipt_path)))
              if current.st_dev == original.st_dev && current.st_ino == original.st_ino &&
                 (current.st_mode & LibC::S_IFMT) == LibC::S_IFREG
                journal_dir.unlink(File.basename(receipt_path))
                journal_dir.sync
              end
            end
          end
          journal_dir.close
        end
      end

      private def self.finalization_lock_paths(metadata : Metadata, changes : Array(Change), image : Bool) : Array(String)
        finalization_lock_paths_from_names(metadata, changes.map(&.name), image)
      end

      private def self.finalization_lock_paths_from_names(metadata : Metadata, names : Array(String), image : Bool) : Array(String)
        paths = names.map do |name|
          local = name.starts_with?("refs/worktree/") || name.starts_with?("refs/bisect/") ||
                  name.starts_with?("refs/rewritten/")
          File.join(local ? metadata.git_dir : metadata.common, name + ".lock")
        end
        paths << File.join(metadata.common, "packed-refs.lock")
        paths << index_lock(metadata) if image
        paths.uniq!.sort!
      end

      private def self.finalization_marker(token : String) : String
        "#{FINAL_LOCK_MAGIC}\t#{token}\n"
      end

      private def self.checksum_file!(path : String, max_bytes : Int32) : String
        dir, name = DescriptorPath::Directory.open_parent(path)
        begin
          io = dir.open_file(name, LibC::O_RDONLY)
        rescue
          dir.close
          raise Conflict.new("Git recovery file missing or redirected")
        end
        begin
          raise Conflict.new("Git recovery file not regular") unless io.info.type.file?
          mem = IO::Memory.new
          IO.copy(io, mem, max_bytes.to_i64 + 1)
          raise Error.new("Git recovery file exceeds byte budget") if mem.size > max_bytes
          Digest::SHA256.hexdigest(mem.to_slice)
        ensure
          io.close unless io.closed?
          dir.close
        end
      end

      # No arbitrary filesystem paths occur in this receipt. Git ref names are
      # decoded and revalidated; target lock paths are derived from Metadata.
      private def self.encode_finalization(metadata : Metadata, format : ObjectId::Format,
                                           receipt : Finalization) : String
        body = String.build do |io|
          io << FINALIZATION_MAGIC << '\n'
          io << (format == ObjectId::Format::SHA1 ? "sha1" : "sha256") << '\n'
          io << metadata.git_dir.to_slice.hexstring << '\n'
          io << receipt.token << '\n'
          io << receipt.redo_checksum << '\n'
          io << (receipt.index_checksum || "-") << '\n'
          io << receipt.refs.size << '\n'
          receipt.refs.each do |name, desired|
            io << name.to_slice.hexstring << '\t' << (desired || "-") << '\n'
          end
        end
        "#{Digest::SHA256.hexdigest(body)}\n#{body}"
      end

      private def self.write_finalization!(metadata : Metadata, path : String,
                                           receipt : Finalization,
                                           pinned : DescriptorPath::Directory? = nil) : Nil
        raw = encode_finalization(metadata, metadata.object_format, receipt)
        raise Error.new("Git finalization receipt too large") if raw.bytesize > MAX_FINALIZATION_BYTES
        dir = pinned || DescriptorPath::Directory.open(File.dirname(path))
        begin
          io = dir.open_file(File.basename(path), LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        rescue
          dir.close unless pinned
          raise Conflict.new("Git finalization receipt already exists")
        end
        begin
          io.write(raw.to_slice)
          io.flush
          io.fsync
          dir.sync
        ensure
          io.close unless io.closed?
          dir.close unless pinned
        end
      end

      private def self.read_finalization!(metadata : Metadata, format : ObjectId::Format, path : String) : Finalization
        dir, name = DescriptorPath::Directory.open_parent(path)
        begin
          io = dir.open_file(name, LibC::O_RDONLY)
        rescue
          dir.close
          raise Error.new("Git finalization receipt missing or redirected")
        end
        raw = begin
          raise Error.new("Git finalization receipt not regular") unless io.info.type.file?
          mem = IO::Memory.new
          IO.copy(io, mem, MAX_FINALIZATION_BYTES.to_i64 + 1)
          raise Error.new("Git finalization receipt exceeds byte budget") if mem.size > MAX_FINALIZATION_BYTES
          mem.to_s
        ensure
          io.close unless io.closed?
          dir.close
        end
        parts = raw.split('\n')
        raise Error.new("invalid Git finalization receipt") if parts.size < 9 || !raw.ends_with?('\n')
        checksum = parts.shift
        body = raw.byte_slice(checksum.bytesize + 1, raw.bytesize - checksum.bytesize - 1)
        raise Error.new("Git finalization receipt checksum mismatch") unless checksum == Digest::SHA256.hexdigest(body)
        raise Error.new("unsupported Git finalization format") unless parts.shift == FINALIZATION_MAGIC
        raise Error.new("Git finalization object format mismatch") unless parts.shift == (format == ObjectId::Format::SHA1 ? "sha1" : "sha256")
        raise Error.new("Git finalization belongs to another worktree") unless decode_hex!(parts.shift) == metadata.git_dir
        token = parts.shift
        raise Error.new("invalid Git finalization owner token") unless /\A[0-9a-f]{48}\z/.matches?(token)
        redo = parts.shift
        raise Error.new("invalid Git finalization redo hash") unless /\A[0-9a-f]{64}\z/.matches?(redo)
        index_sha = parts.shift
        raise Error.new("invalid Git finalization index hash") unless index_sha == "-" || /\A[0-9a-f]{64}\z/.matches?(index_sha)
        count = parts.shift.to_i?
        raise Error.new("invalid Git finalization ref count") unless count && count > 0 && count <= MAX_CHANGES && parts.size == count + 1 && parts.last.empty?
        refs = [] of {String, String?}
        previous = ""
        parts.shift(count).each do |line|
          fields = line.split('\t')
          raise Error.new("invalid Git finalization ref entry") unless fields.size == 2
          name = decode_hex!(fields[0])
          RefName.valid!(name)
          raise Error.new("invalid Git finalization ref scope") unless name.starts_with?("refs/")
          raise Error.new("duplicate or overlapping Git finalization refs") unless previous.empty? || (name > previous && !name.starts_with?(previous + "/"))
          previous = name
          desired = fields[1] == "-" ? nil : ObjectId.valid!(fields[1], format)
          refs << {name, desired}
        end
        Finalization.new(token, redo, refs, index_sha == "-" ? nil : index_sha)
      end

      # :nodoc:
      # A completed redo may have been unlinked before SIGKILL/_exit, leaving
      # only this receipt plus our token-marked locks. The operation is
      # intentionally explicit: never infer ownership of an arbitrary .lock.
      def self.finish_finalization(metadata : Metadata, format : ObjectId::Format, id : String,
                                   after_validation : Proc(Nil)? = nil) : Nil
        validate_id!(id)
        metadata.check!
        directory = directory?(metadata)
        raise Error.new("Git finalization receipt missing") unless directory
        with_repository_guard(directory) do
          journal_dir = DescriptorPath::Directory.open(directory)
          receipt_io = nil.as(IO::FileDescriptor?)
          begin
            path = File.join(directory, "#{id}.finish")
            receipt_io = journal_dir.open_file?(File.basename(path), LibC::O_RDONLY)
            raise Error.new("Git finalization receipt missing") unless receipt_io
            receipt = read_finalization!(metadata, format, path)
            raise Conflict.new("Git finalization receipt inode replaced") unless journal_dir.same_inode?(File.basename(path), receipt_io)
            paths = finalization_lock_paths_from_names(metadata, receipt.refs.map { |entry| entry[0] }, !!receipt.index_checksum)
            # Validate EVERY existing lock before removing ANY; reject a foreign
            # writer's replacement even if another owned lock is still present.
            owned = [] of {String, DescriptorPath::Directory, String, IO::FileDescriptor}
            begin
              paths.each do |lock_path|
                dir, name = DescriptorPath::Directory.open_parent(lock_path)
                begin
                  io = dir.open_file?(name)
                rescue
                  dir.close
                  raise Conflict.new("Git finalization foreign or redirected lock: #{lock_path}")
                end
                unless io
                  dir.close
                  next
                end
                owned << {lock_path, dir, name, io}
                raise Conflict.new("Git finalization foreign lock: #{lock_path}") unless io.info.type.file?
                mem = IO::Memory.new
                IO.copy(io, mem, 257_i64)
                raise Conflict.new("Git finalization foreign lock: #{lock_path}") unless mem.to_s == finalization_marker(receipt.token)
              end
              receipt.refs.each do |name, desired|
                raise Conflict.new("Git finalization ref diverged: #{PathBytes.quote(name)}") unless metadata.resolve_ref?(name) == desired
              end
              if digest = receipt.index_checksum
                actual = checksum_file!(File.join(metadata.git_dir, "index"), MAX_INDEX_IMAGE_BYTES)
                raise Conflict.new("Git finalization index diverged") unless actual == digest
              end
              redo_path = File.join(directory, "#{id}.redo")
              if File.exists?(redo_path) || File.symlink?(redo_path)
                raise Conflict.new("Git finalization redo diverged") unless checksum_file!(redo_path, MAX_INDEX_JOURNAL_BYTES) == receipt.redo_checksum
                # The original finalizer published all reflogs before writing
                # its receipt, so a matching redo and state are sufficient here.
                raise Conflict.new("Git finalization journal parent replaced") unless journal_dir.attached_at?(directory)
                journal_dir.unlink(File.basename(redo_path))
                journal_dir.sync
              end
              # Low-level test seam for deterministic parent relocation after
              # all ref/index and marker checks, before the first unlink.
              after_validation.try &.call
              raise Conflict.new("Git finalization lock parent replaced") unless owned.all? do |lock_path, dir, _, _|
                                                                                   dir.attached_at?(File.dirname(lock_path))
                                                                                 end
              owned.each do |lock_path, dir, name, io|
                raise Conflict.new("Git finalization lock replaced: #{lock_path}") unless dir.same_inode?(name, io)
                dir.unlink(name)
                dir.sync
              end
              raise Conflict.new("Git finalization receipt parent replaced") unless journal_dir.attached_at?(directory)
              raise Conflict.new("Git finalization receipt inode replaced") unless journal_dir.same_inode?(File.basename(path), receipt_io.not_nil!)
              journal_dir.unlink(File.basename(path))
              journal_dir.sync
            ensure
              owned.each do |_, dir, _, io|
                io.close unless io.closed?
                dir.close
              end
            end
          ensure
            receipt_io.try { |io| io.close unless io.closed? }
            journal_dir.close
          end
        end
      end

      # Never delete this shared lock file: unlinking it could split flock
      # ownership across two inodes. Git itself does not honor this guard.
    end
  end
end
