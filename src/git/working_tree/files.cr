module Git
  class WorkingTree
    # One owner for verifying on-disk working-file ancestors. Never follow a
    # symlinked parent, including when inspecting an indexed symlink itself.
    # Missing parents are allowed: a missing tracked file is a deletion.
    # verified, when given, remembers directories already checked during
    # one scan so each is checked once.
    private def verify_working_parents!(relative : String, verified : Set(String)? = nil, &check : -> Nil) : Nil
      PathBytes.validate_relative!(relative, max_depth: Metadata::MAX_DEPTH)
      parent = @root
      relative.split('/')[0...-1].each do |part|
        check.call
        parent = File.join(parent, part)
        next if verified && verified.includes?(parent)
        raise Error.new("Git working directory is a symlink") if File.symlink?(parent)
        if File.exists?(parent)
          raise Error.new("Git working directory redirected") unless Dir.exists?(parent) && File.realpath(parent) == parent
          verified.try &.add(parent)
        end
      end
    end

    # Whether an indexed regular file is unchanged by its stat data alone,
    # so it need not be read and hashed.
    protected def stat_unchanged?(entry : Index::Entry, mode_sensitive : Bool, index_time : Time?,
                                  verified : Set(String), &check : -> Nil) : Bool
      return false unless entry.stat && index_time && entry.mode.starts_with?("100")
      verify_working_parents!(entry.path, verified) { check.call }
      stat = uninitialized LibC::Stat
      return false unless LibC.lstat(File.join(@root, entry.path), pointerof(stat)) == 0
      (stat.st_mode & LibC::S_IFMT) == LibC::S_IFREG && stat_clean?(entry, stat, index_time, mode_sensitive)
    end

    # Git's ce_match_stat for a regular file: the same times, inode, owner,
    # size and (with core.filemode) executable bit as the index recorded,
    # and not modified in the second the index was written or later
    # (racily clean), which only reading the contents can settle. A
    # recorded nanosecond field of zero compares seconds only.
    private def stat_clean?(entry : Index::Entry, stat : LibC::Stat, index_time : Time?,
                            mode_sensitive : Bool) : Bool
      recorded = entry.stat
      return false unless recorded && index_time
      mtime, ctime = {% if flag?(:darwin) %}{stat.st_mtimespec, stat.st_ctimespec}{% else %}{stat.st_mtim, stat.st_ctim}{% end %}
      return false unless recorded.mtime == mtime.tv_sec.to_u32! && recorded.ctime == ctime.tv_sec.to_u32!
      return false unless recorded.mtime_nsec == 0 || recorded.mtime_nsec == mtime.tv_nsec.to_u32!
      return false unless recorded.ctime_nsec == 0 || recorded.ctime_nsec == ctime.tv_nsec.to_u32!
      return false unless recorded.ino == stat.st_ino.to_u32! && recorded.uid == stat.st_uid.to_u32! &&
                          recorded.gid == stat.st_gid.to_u32! && recorded.size == stat.st_size.to_u32!
      return false if mode_sensitive && (entry.mode == "100755") != (stat.st_mode & 0o100 != 0)
      recorded.mtime.to_i64 < index_time.to_unix
    end

    # The working-tree state of one indexed path as (mode, object ID,
    # contents), or nil when nothing is there (or not a file or link).
    # Symlinks are read as their target text. Without mode_sensitive the
    # index decides the executable bit of a regular file.
    protected def snapshot(entry : Index::Entry, max_bytes : Int32, mode_sensitive : Bool,
                           &check : -> Nil) : {String, String, String}?
      verify_working_parents!(entry.path) { check.call }
      absolute = File.join(@root, entry.path)
      if File.symlink?(absolute)
        target = File.readlink(absolute)
        raise Error.new("Git working file exceeds byte budget") if target.bytesize > max_bytes
        {"120000", ObjectId.digest("blob", target, @object_format), target}
      elsif File.file?(absolute)
        oid, mode, text = read_working_regular(entry.path, max_bytes) { check.call }
        mode = entry.mode if !mode_sensitive && (entry.mode == "100644" || entry.mode == "100755")
        {mode, oid, text}
      end
    rescue ex : IO::Error
      raise Error.new("Git working diff I/O invalid: #{ex.class}")
    end

    # Shared bounded, identity-checked regular-file read for worktree status
    # and per-file diffs. The caller is responsible for path authorization.
    private def read_working_regular(relative : String, max_bytes : Int32, &check : -> Nil) : {String, String, String}
      verify_working_parents!(relative) { check.call }
      absolute = File.join(@root, relative)
      raise Error.new("Git working file is a symlink or not regular") if File.symlink?(absolute) || !File.file?(absolute) || File.realpath(absolute) != absolute
      before = File.info(absolute, follow_symlinks: false)
      raise Error.new("Git working file exceeds byte budget") if before.size > max_bytes || before.size > @max_scan_bytes
      buffer = IO::Memory.new
      File.open(absolute) do |file|
        opened = file.info
        raise Error.new("Git working file changed before read") unless opened.same_file?(before)
        IO.copy(file, buffer, max_bytes.to_i64 + 1)
      end
      check.call
      verify_working_parents!(relative) { check.call }
      after = File.info(absolute, follow_symlinks: false)
      raise Error.new("Git working file changed during read") unless after.same_file?(before) &&
                                                                     after.size == before.size &&
                                                                     after.modification_time == before.modification_time &&
                                                                     after.permissions == before.permissions &&
                                                                     buffer.size == before.size && !File.symlink?(absolute)
      text = buffer.to_s
      {ObjectId.digest("blob", text, @object_format), after.permissions.value & 0o111 != 0 ? "100755" : "100644", text}
    end
  end
end
