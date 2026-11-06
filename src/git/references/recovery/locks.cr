module Git
  struct References
    struct Recovery
      private def self.with_repository_guard(directory : String, &block : ->) : Nil
        dir = DescriptorPath::Directory.open(directory)
        begin
          io = dir.open_file(GUARD_FILE, LibC::O_RDWR | LibC::O_CREAT, 0o600)
        rescue
          dir.close
          raise Error.new("Git recovery repository guard unavailable")
        end
        begin
          raise Error.new("Git recovery repository guard redirected") unless io.info.type.file? && dir.same_inode?(GUARD_FILE, io)
          operation = LibC::FlockOp::EX | LibC::FlockOp::NB
          raise Error.new("Git recovery repository is busy") if LibC.flock(io.fd, operation) < 0
          raise Error.new("Git recovery repository directory replaced") unless dir.attached_at?(directory)
          yield
        ensure
          io.close unless io.closed?
          dir.close
        end
      end

      private def self.require_unpublished_refs!(metadata : Metadata, changes : Array(Change)) : Nil
        changes.each do |change|
          raise Error.new("Git ref compare-and-swap mismatch") unless metadata.resolve_ref?(change.name) == change.expected_oid
        end
      end

      private def self.remaining_changes(metadata : Metadata, changes : Array(Change)) : Array(Change)
        pending = [] of Change
        changes.each do |change|
          actual = metadata.resolve_ref?(change.name)
          desired = change.is_a?(Update) ? change.new_oid : nil
          next if actual == desired
          unless actual == change.expected_oid
            raise Conflict.new("Git recovery conflict on #{PathBytes.quote(change.name)}")
          end
          pending << change
        end
        pending
      end

      private def self.validate_id!(id : String) : Nil
        raise Error.new("invalid Git recovery identifier") unless valid_id?(id)
      end

      private def self.valid_id?(id : String) : Bool
        !!(/\A[A-Za-z0-9_-]{1,64}\z/.match(id))
      end

      private def self.directory?(metadata : Metadata) : String?
        directory = File.join(metadata.common, DIRECTORY)
        return nil unless Dir.exists?(directory) || File.symlink?(directory) || File.exists?(directory)
        raise Error.new("Git recovery directory redirected") unless Dir.exists?(directory) && !File.symlink?(directory) && File.realpath(directory) == directory
        directory
      end

      private def self.directory!(metadata : Metadata) : String
        directory = File.join(metadata.common, DIRECTORY)
        unless Dir.exists?(directory)
          raise Error.new("Git recovery directory redirected") if File.exists?(directory) || File.symlink?(directory)
          DescriptorPath::Directory.with_parent(directory) do |dir, name|
            dir.mkdir(name)
            dir.sync
          end
        end
        directory?(metadata).not_nil!
      end

      private def self.sync_directory!(path : String) : Nil
        File.open(path) { |io| io.fsync }
      end

      private def self.lock!(fd : Int32) : Nil
        operation = LibC::FlockOp::EX | LibC::FlockOp::NB
        raise Error.new("Git recovery journal is busy") if LibC.flock(fd, operation) < 0
      end

      private def self.clear_deleted_ref_log!(metadata : Metadata, name : String) : Nil
        local = name.starts_with?("refs/worktree/") || name.starts_with?("refs/bisect/") ||
                name.starts_with?("refs/rewritten/")
        base = local ? metadata.git_dir : metadata.common
        directory = base
        (["logs"] + name.split('/')[0...-1]).each do |component|
          directory = File.join(directory, component)
          return unless File.exists?(directory) || File.symlink?(directory)
          raise Error.new("Git recovery reflog parent redirected") unless Dir.exists?(directory) &&
                                                                          !File.symlink?(directory) && File.realpath(directory) == directory
        end
        target = File.join(directory, name.split('/').last)
        raise Error.new("Git recovery reflog redirected") if File.symlink?(target) || Dir.exists?(target)
        if File.file?(target)
          File.delete(target)
          sync_directory!(directory)
        end
      end

      private def self.ref_lock_paths(metadata : Metadata, changes : Array(Change)) : Array(String)
        locks = changes.map do |change|
          local = change.name.starts_with?("refs/worktree/") || change.name.starts_with?("refs/bisect/") ||
                  change.name.starts_with?("refs/rewritten/")
          File.join(local ? metadata.git_dir : metadata.common, change.name + ".lock")
        end
        if changes.any? { |c| c.is_a?(Delete) }
          locks << File.join(metadata.common, "packed-refs.lock")
        end
        locks
      end

      private def self.index_lock(metadata : Metadata) : String
        File.join(metadata.git_dir, "index.lock")
      end

      private def self.refuse_index_lock!(metadata : Metadata) : Nil
        path = index_lock(metadata)
        raise Error.new("Git recovery blocked by index lock: #{path}") if File.exists?(path) || File.symlink?(path)
      end

      private def self.clear_index_lock!(metadata : Metadata) : Nil
        path = index_lock(metadata)
        return unless File.exists?(path) || File.symlink?(path)
        raise Error.new("Git recovery index lock redirected") unless File.file?(path) && !File.symlink?(path)
        File.delete(path)
        sync_directory!(metadata.git_dir)
      end

      private def self.refuse_locks!(metadata : Metadata, changes : Array(Change)) : Nil
        ref_lock_paths(metadata, changes).each do |path|
          raise Error.new("Git recovery blocked by ref lock: #{path}") if File.exists?(path) || File.symlink?(path)
        end
      end

      # This is an explicit maintenance-only action. A Git .lock has no
      # ownership token. The caller must independently ensure no ordinary Git
      # writer is alive; the journal's flock only serializes our own redo APIs.
      private def self.clear_locks!(metadata : Metadata, changes : Array(Change)) : Nil
        locks = ref_lock_paths(metadata, changes)
        # The finalization barrier takes packed-refs.lock for *every* batch,
        # including update-only batches. A killed finalizer can therefore
        # leave it behind even when no packed refs were removed.
        locks << File.join(metadata.common, "packed-refs.lock")
        locks.uniq.each do |path|
          next unless File.exists?(path) || File.symlink?(path)
          raise Error.new("Git recovery lock redirected") unless File.file?(path) && !File.symlink?(path)
          File.delete(path)
          sync_directory!(File.dirname(path))
        end
      end
    end
  end
end
