module Git
  struct References
    struct Recovery
      # A reflog replay step is tied to the exact previous file prefix and
      # complete encoded entry. The journal stores only a digest of the
      # previous bytes, not their potentially large or private content.
      record LogIntent, private_base : Bool, relative : String, line : String,
        before_size : Int32, before_sha256 : String, attached_ref : String? = nil

      MAX_REFLOG_BYTES = 8_388_608

      def self.log_intents(metadata : Metadata, format : ObjectId::Format,
                           changes : Array(Change)) : Array(LogIntent)
        attached, _ = metadata.head
        logs = [] of LogIntent
        changes.each do |change|
          next unless change.is_a?(Update)
          next unless log = change.log
          line = log.encode(change.expected_oid || "0" * format.hexsize, change.new_oid)
          local = local_ref?(change.name)
          logs << capture_log(metadata, local, change.name, line)
          if attached == change.name
            logs << capture_log(metadata, true, "HEAD", line, change.name)
          end
        end
        logs
      end

      private def self.local_ref?(name : String) : Bool
        name.starts_with?("refs/worktree/") || name.starts_with?("refs/bisect/") ||
          name.starts_with?("refs/rewritten/")
      end

      private def self.log_path(metadata : Metadata, log : LogIntent) : String
        File.join(log.private_base ? metadata.git_dir : metadata.common, "logs", log.relative)
      end

      private def self.log_directory!(path : String, *, create : Bool) : Nil
        components = [] of String
        current = File.dirname(path)
        until current == File.dirname(current)
          components << current
          current = File.dirname(current)
        end
        components.reverse_each do |directory|
          if !Dir.exists?(directory)
            raise Error.new("Git recovery reflog parent redirected") if File.exists?(directory) || File.symlink?(directory)
            if create
              Dir.mkdir(directory)
            else
              # A missing parent is allowed during journal preparation.
              next
            end
          end
          if Dir.exists?(directory)
            raise Error.new("Git recovery reflog parent redirected") if File.symlink?(directory) || File.realpath(directory) != directory
          end
        end
      end

      private def self.read_log?(path : String) : String?
        log_directory!(path, create: false)
        info = File.info?(path, follow_symlinks: false)
        return nil unless info
        raise Error.new("Git recovery reflog redirected") unless info.type.file? && !File.symlink?(path)
        raise Error.new("Git recovery reflog byte budget exceeded") if info.size > MAX_REFLOG_BYTES
        fd = LibC.open(path, LibC::O_RDONLY | LibC::O_CLOEXEC | LibC::O_NOFOLLOW)
        raise Error.new("Git recovery reflog unreadable") if fd < 0
        io = IO::FileDescriptor.new(fd)
        begin
          memory = IO::Memory.new
          IO.copy(io, memory, MAX_REFLOG_BYTES.to_i64 + 1)
          raise Error.new("Git recovery reflog byte budget exceeded") if memory.size > MAX_REFLOG_BYTES
          memory.to_s
        ensure
          io.close
        end
      end

      private def self.capture_log(metadata : Metadata, private_base : Bool,
                                   relative : String, line : String,
                                   attached_ref : String? = nil) : LogIntent
        path = File.join(private_base ? metadata.git_dir : metadata.common, "logs", relative)
        before = read_log?(path) || ""
        raise Error.new("Git recovery reflog entry budget exceeded") if line.bytesize > 4096 ||
                                                                        before.bytesize + line.bytesize > MAX_REFLOG_BYTES
        LogIntent.new(private_base, relative, line, before.bytesize,
          Digest::SHA256.hexdigest(before), attached_ref)
      end

      def self.validate_logs!(changes : Array(Change), logs : Array(LogIntent),
                              format : ObjectId::Format) : Nil
        raise Error.new("Git recovery reflog count exceeded") if logs.size > MAX_CHANGES * 2
        seen = Set({Bool, String}).new
        logs.each do |log|
          raise Error.new("duplicate Git recovery reflog") unless seen.add?({log.private_base, log.relative})
          raise Error.new("invalid Git recovery reflog digest") unless /\A[0-9a-f]{64}\z/.matches?(log.before_sha256)
          raise Error.new("invalid Git recovery reflog baseline") unless (0..MAX_REFLOG_BYTES).includes?(log.before_size)
          raise Error.new("invalid Git recovery reflog entry") unless log.line.bytesize <= 4096 &&
                                                                      log.line.ends_with?('\n') && log.line.count('\n') == 1 && !log.line.includes?('\0')
          change = if log.relative == "HEAD"
                     raise Error.new("Git recovery HEAD reflog missing attachment") unless log.private_base && log.attached_ref
                     changes.find { |entry| entry.is_a?(Update) && entry.name == log.attached_ref }
                   else
                     raise Error.new("Git recovery reflog path invalid") unless log.attached_ref.nil? && log.relative.starts_with?("refs/")
                     RefName.valid!(log.relative)
                     raise Error.new("Git recovery reflog scope invalid") unless log.private_base == local_ref?(log.relative)
                     changes.find { |entry| entry.is_a?(Update) && entry.name == log.relative }
                   end
          raise Error.new("Git recovery reflog has no update") unless change.is_a?(Update)
          prefix = "#{change.expected_oid || "0" * format.hexsize} #{change.new_oid} "
          raise Error.new("Git recovery reflog OIDs mismatch") unless log.line.starts_with?(prefix)
        end
      end

      private def self.log_progress!(current : String, log : LogIntent) : Int32
        raise Conflict.new("Git recovery reflog truncated") if current.bytesize < log.before_size
        original = current.byte_slice(0, log.before_size)
        raise Conflict.new("Git recovery reflog diverged") unless Digest::SHA256.hexdigest(original) == log.before_sha256
        suffix_len = current.bytesize - log.before_size
        raise Conflict.new("Git recovery reflog diverged") if suffix_len > log.line.bytesize
        suffix = current.byte_slice(log.before_size, suffix_len)
        raise Conflict.new("Git recovery reflog diverged") unless log.line.starts_with?(suffix)
        suffix_len
      end

      # All log files are checked before any append. A partial append can be
      # resumed byte-for-byte, and a complete append is never duplicated.
      # External Git writers do not participate in this journal lock: their
      # concurrent modifications are detected when observed, not excluded.
      def self.replay_logs!(metadata : Metadata, changes : Array(Change),
                            logs : Array(LogIntent), format : ObjectId::Format,
                            after_reflog : Proc(String, Nil)? = nil) : Nil
        validate_logs!(changes, logs, format)
        logs.each do |log|
          if attached = log.attached_ref
            raise Conflict.new("Git HEAD moved during recovery") unless metadata.head[0] == attached
          end
          log_progress!(read_log?(log_path(metadata, log)) || "", log)
        end
        logs.each do |log|
          path = log_path(metadata, log)
          log_directory!(path, create: true)
          raise Error.new("Git recovery reflog redirected") if File.symlink?(path) || Dir.exists?(path)
          fd = LibC.open(path, LibC::O_RDWR | LibC::O_CREAT | LibC::O_APPEND | LibC::O_NOFOLLOW | LibC::O_CLOEXEC, 0o666)
          raise Error.new("Git recovery reflog unavailable") if fd < 0
          io = IO::FileDescriptor.new(fd)
          begin
            raw = IO::Memory.new
            IO.copy(io, raw, MAX_REFLOG_BYTES.to_i64 + 1)
            raise Error.new("Git recovery reflog byte budget exceeded") if raw.size > MAX_REFLOG_BYTES
            written = log_progress!(raw.to_s, log)
            if written < log.line.bytesize
              tail = log.line.byte_slice(written, log.line.bytesize - written)
              io.write(tail.to_slice)
              io.flush
              io.fsync
            end
          ensure
            io.close
          end
          File.open(File.dirname(path)) { |directory| directory.fsync }
          after_reflog.try &.call(log.relative)
        end
      end

      private def self.without_logs(changes : Array(Change)) : Array(Change)
        result = [] of Change
        changes.each do |change|
          if change.is_a?(Update)
            result << Update.new(change.name, change.new_oid, change.expected_oid)
          else
            result << change
          end
        end
        result
      end
    end
  end
end
