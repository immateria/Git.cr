module Git
  struct References
    struct Recovery
      protected def self.list(metadata : Metadata) : Array(String)
        directory = directory?(metadata)
        return [] of String unless directory
        ids = [] of String
        Dir.each_child(directory) do |entry|
          next unless entry.ends_with?(".redo")
          id = entry.byte_slice(0, entry.bytesize - 5)
          next unless valid_id?(id)
          path = File.join(directory, entry)
          raise Error.new("Git recovery journal redirected") if File.symlink?(path) || !File.file?(path)
          ids << id
          raise Error.new("Git recovery journal listing budget exceeded") if ids.size > 1024
        end
        ids.sort!
      end

      protected def self.pending_finalizations(metadata : Metadata) : Array(String)
        directory = directory?(metadata)
        return [] of String unless directory
        ids = [] of String
        Dir.each_child(directory) do |entry|
          next unless entry.ends_with?(".finish")
          id = entry.byte_slice(0, entry.bytesize - 7)
          next unless valid_id?(id)
          path = File.join(directory, entry)
          raise Error.new("Git finalization receipt redirected") if File.symlink?(path) || !File.file?(path)
          ids << id
          raise Error.new("Git finalization listing budget exceeded") if ids.size > 1024
        end
        ids.sort!
      end

      # :nodoc:
      def self.run(metadata : Metadata, format : ObjectId::Format, id : String,
                   changes : Array(Change), after_reflog : Proc(String, Nil)? = nil,
                   index_image : Index::Image? = nil,
                   index_store : Index? = nil,
                   index_check : Proc(Nil)? = nil,
                   after_index_publish : Proc(Nil)? = nil,
                   finalization_probe : Proc(Nil)? = nil,
                   after_journal_unlink : Proc(Nil)? = nil,
                   after_receipt_durable : Proc(Nil)? = nil,
                   &block : Array(Change) ->) : Nil
        validate_id!(id)
        validate!(changes, format)
        metadata.check!
        directory = directory!(metadata)
        with_repository_guard(directory) do
          # The persistent guard coordinates only this native recovery API.
          # Git's independent ref/index lock files are checked separately.
          raise Error.new("Git recovery pending journal must be resolved first") unless list(metadata).empty?
          raise Error.new("Git recovery pending finalization must be finished first") unless pending_finalizations(metadata).empty?
          if image = index_image
            raise Error.new("Git index publisher required for recovery") unless index_store
            raise Error.new("Git index already diverged from journal predecessor") unless index_store.image_state(image, max_bytes: MAX_INDEX_IMAGE_BYTES) == :before
          end
          path = File.join(directory, "#{id}.redo")
          logs = log_intents(metadata, format, changes)
          raw = encode(metadata, format, changes, logs, index_image)
          limit = index_image ? MAX_INDEX_JOURNAL_BYTES : MAX_BYTES
          raise Error.new("Git recovery journal exceeds byte budget") if raw.bytesize > limit
          journal_dir = DescriptorPath::Directory.open(directory)
          begin
            io = journal_dir.open_file(File.basename(path), LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL, 0o600)
          rescue
            journal_dir.close
            raise Error.new("Git recovery journal already exists or cannot be created")
          end
          begin
            lock!(io.fd)
            begin
              io.write(raw.to_slice)
              io.flush
              io.fsync
              journal_dir.sync
            rescue ex
              # Remove only the leaf we created, even if another writer
              # replaced the original journal inode after our openat.
              journal_dir.unlink(File.basename(path)) if journal_dir.same_inode?(File.basename(path), io)
              journal_dir.sync
              raise ex
            end
            index_attempted = false
            begin
              if image = index_image
                require_unpublished_refs!(metadata, changes)
                refuse_locks!(metadata, changes)
                refuse_index_lock!(metadata)
                index_attempted = true
                index_store.not_nil!.publish_image(image, max_bytes: MAX_INDEX_IMAGE_BYTES, check: index_check)
                after_index_publish.try &.call
              end
              yield without_logs(changes)
            rescue ex : PartialPublication
              raise ex
            rescue ex
              # Once index publication starts, an ordinary exception may occur
              # after an independent rename. Preserve the redo journal even if
              # the ref batch has not published anything yet.
              if index_attempted
                raise PartialPublication.new([] of String, false, false, ex)
              end
              raise Error.new("Git recovery journal parent replaced") unless journal_dir.attached_at?(directory)
              raise Error.new("Git recovery journal inode replaced") unless journal_dir.same_inode?(File.basename(path), io)
              journal_dir.unlink(File.basename(path))
              journal_dir.sync
              raise ex
            end
            begin
              verify_published!(metadata, changes, index_image, index_store)
            rescue ex
              # All original ref locks have been released. A different Git
              # process can now advance a ref; retain the journal on divergence.
              raise PartialPublication.new(changes.map(&.name), false, false, ex)
            end
            begin
              replay_logs!(metadata, changes, logs, format, after_reflog)
              verify_published!(metadata, changes, index_image, index_store)
              # Reacquire Git-native locks for final state validation AND
              # journal unlink. A competing Git lock or divergent ref/index
              # after publication is a partial publication, never a clean
              # transaction failure or permission to discard the journal.
              finalize_journal!(metadata, directory, path, changes, index_image, index_store,
                finalization_probe, after_journal_unlink, after_receipt_durable, io)
            rescue ex
              # Refs have already published. A partial or complete reflog
              # append and any failed finalization are recoverable; preserve
              # the redo record for explicit resolution.
              raise PartialPublication.new(changes.map(&.name), false, true, ex)
            end
          ensure
            io.close unless io.closed?
            journal_dir.close
          end
        end # persistent repository guard
      end

      # Reconcile all journaled references, then redo only operations still
      # at their exact expected old OIDs. Ref values that are neither old nor
      # desired are conflicts; the journal is preserved for manual review.
      # Stale ref .lock files from a killed process are NEVER removed unless
      # the trusted caller explicitly certifies exclusive repository access.
      protected def self.resume(metadata : Metadata, format : ObjectId::Format, id : String, *,
                                clear_abandoned_locks : Bool = false,
                                check : Proc(Nil)? = nil,
                                after_reflog : Proc(String, Nil)? = nil,
                                index_store : Index? = nil,
                                index_check : Proc(Nil)? = nil,
                                after_index_publish : Proc(Nil)? = nil,
                                &publish : Array(Change) ->) : Nil
        validate_id!(id)
        metadata.check!
        directory = directory?(metadata)
        raise Error.new("Git recovery journal missing") unless directory
        with_repository_guard(directory) do
          if File.exists?(File.join(directory, "#{id}.finish")) || File.symlink?(File.join(directory, "#{id}.finish"))
            raise Error.new("Git recovery finalization receipt pending; finish finalization first")
          end
          path = File.join(directory, "#{id}.redo")
          journal_dir = DescriptorPath::Directory.open(directory)
          begin
            io = journal_dir.open_file(File.basename(path), LibC::O_RDONLY)
          rescue
            journal_dir.close
            raise Error.new("Git recovery journal missing or redirected")
          end
          begin
            raise Error.new("Git recovery journal not regular") unless io.info.type.file?
            lock!(io.fd)
            data = IO::Memory.new
            IO.copy(io, data, MAX_INDEX_JOURNAL_BYTES.to_i64 + 1)
            raise Error.new("Git recovery journal exceeds byte budget") if data.size > MAX_INDEX_JOURNAL_BYTES
            stored = decode(data.to_s, metadata, format)
            image = stored.index
            if image
              raise Error.new("Git index publisher required for joint recovery") unless index_store
              index_store.image_state(image, max_bytes: MAX_INDEX_IMAGE_BYTES)
            end
            changes = stored.changes
            check.try &.call
            # Check the ENTIRE batch before any cleanup or mutation, including
            # already-published references, to avoid overwriting third parties.
            remaining = remaining_changes(metadata, changes)
            check.try &.call
            if clear_abandoned_locks
              clear_locks!(metadata, changes)
              clear_index_lock!(metadata) if image
            else
              refuse_locks!(metadata, changes)
              refuse_index_lock!(metadata) if image
            end
            if image
              if index_store.not_nil!.image_state(image, max_bytes: MAX_INDEX_IMAGE_BYTES) == :before
                index_store.not_nil!.publish_image(image, max_bytes: MAX_INDEX_IMAGE_BYTES, check: index_check)
                after_index_publish.try &.call
              end
            end
            publish.call(without_logs(remaining)) unless remaining.empty?
            if image
              raise Conflict.new("Git recovery incomplete: index changed during redo") unless index_store.not_nil!.image_state(image, max_bytes: MAX_INDEX_IMAGE_BYTES) == :desired
            end
            unless remaining_changes(metadata, changes).empty?
              raise Conflict.new("Git recovery incomplete: refs changed during redo")
            end
            replay_logs!(metadata, changes, stored.logs, format, after_reflog)
            # The original writer removes reflogs only after all refs publish.
            # A killed writer may leave the log for an already-deleted ref.
            changes.each do |change|
              clear_deleted_ref_log!(metadata, change.name) if change.is_a?(Delete)
            end
            # Preserve the record on conflicts or foreign Git lock ownership.
            # Final-state validation and journal unlink share the Git-native
            # lock lifetime, rather than leaving an unlocked race between them.
            finalize_journal!(metadata, directory, path, changes, image, index_store,
              expected_redo: io)
          ensure
            io.close unless io.closed?
            journal_dir.close
          end
        end # persistent repository guard
      end
    end
  end
end
