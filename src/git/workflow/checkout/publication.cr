module Git
  module Checkout
    # Publish one complete blob through a temporary sibling, with the
    # original path constrained to the same pinned directory. Caller has
    # already preflighted all tracked files and untracked destinations.
    def self.write(root : String, write : Write, sequence : Int32, *,
                   expected_old : FileState?, format : ObjectId::Format,
                   check : Proc(Nil)?) : Nil
      if write.mode == "120000"
        return write_symlink(root, write, sequence, expected_old: expected_old,
          format: format, check: check)
      end
      raise Error.new("unsupported Git checkout output mode") unless {"100644", "100755"}.includes?(write.mode)
      dir, leaf, location = parent(root, write.path, create: true)
      temp = ".crystal-git-checkout-#{Process.pid}-#{sequence}.tmp"
      begin
        io = dir.open_file(temp, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        owned = true
        begin
          io.write(write.data.to_slice)
          raise Error.new("Git checkout chmod failed") unless LibC.fchmod(io.fd, write.mode == "100755" ? 0o755 : 0o644) == 0
          io.flush
          io.fsync
          check.try &.call
          raise Error.new("Git checkout parent replaced") unless dir.attached_at?(location)
          validate_old_leaf!(dir, leaf, expected_old, format, check)
          if expected_old
            dir.rename(temp, leaf)
          else
            dir.rename_noreplace(temp, leaf)
          end
          owned = false
          dir.sync
        ensure
          if owned && dir.same_inode?(temp, io)
            dir.unlink(temp)
            dir.sync
          end
          io.close unless io.closed?
        end
      ensure
        dir.close
      end
    end

    # Publish symlink bytes, not the pointed-to file. A pinned directory and
    # owned temporary inode limit path redirection and cleanup interference.
    def self.write_symlink(root : String, write : Write, sequence : Int32, *,
                           expected_old : FileState?, format : ObjectId::Format,
                           check : Proc(Nil)?) : Nil
      raise Error.new("invalid Git symlink target") if write.data.empty? || write.data.includes?('\0') || write.data.bytesize > 4095
      dir, leaf, location = parent(root, write.path, create: true)
      temp = ".crystal-git-checkout-#{Process.pid}-#{sequence}.tmp"
      created = nil.as(LibC::Stat?)
      owned = false
      begin
        created = dir.symlink_new(temp, write.data)
        owned = true
        dir.sync
        check.try &.call
        raise Error.new("Git checkout parent replaced") unless dir.attached_at?(location)
        validate_old_leaf!(dir, leaf, expected_old, format, check)
        if expected_old
          dir.rename(temp, leaf)
        else
          dir.rename_noreplace(temp, leaf)
        end
        owned = false
        dir.sync
      ensure
        if owned && created && dir.same_stat?(temp, created)
          dir.unlink(temp)
          dir.sync
        end
        dir.close
      end
    end

    def self.remove_empty_directory(root : String, path : String, *, check : Proc(Nil)?) : Nil
      dir, leaf, location = parent(root, path, create: false)
      begin
        check.try &.call
        raise Error.new("Git checkout directory parent replaced") unless dir.attached_at?(location)
        stat = dir.stat?(leaf) || raise Error.new("Git checkout transition directory disappeared")
        raise Error.new("Git checkout transition target is not a directory") unless (stat.st_mode & LibC::S_IFMT) == LibC::S_IFDIR
        dir.rmdir(leaf)
        dir.sync
      rescue ex : Git::Error
        if current = dir.stat?(leaf)
          if (current.st_mode & LibC::S_IFMT) == LibC::S_IFDIR
            raise Error.new("Git checkout refuses untracked content in directory transition")
          end
        end
        raise ex
      ensure
        dir.close
      end
    end

    def self.remove(root : String, path : String, old : FileState, *,
                    format : ObjectId::Format, check : Proc(Nil)?) : Nil
      dir, leaf, location = parent(root, path, create: false)
      begin
        check.try &.call
        raise Error.new("Git checkout parent replaced") unless dir.attached_at?(location)
        validate_old_leaf!(dir, leaf, old, format, check)
        dir.unlink(leaf)
        dir.sync
      ensure
        dir.close
      end
    end

    private def self.validate_old_leaf!(dir : DescriptorPath::Directory, leaf : String,
                                        old : FileState?, format : ObjectId::Format,
                                        check : Proc(Nil)?) : Nil
      initial = dir.stat?(leaf)
      if old.nil?
        raise Error.new("Git checkout refuses untracked path collision") if initial
        return
      end
      if old.mode == "120000"
        raise Error.new("Git checkout tracked symlink disappeared") unless initial &&
                                                                           (initial.st_mode & LibC::S_IFMT) == LibC::S_IFLNK
        raw = dir.read_symlink(leaf, 8_388_608)
        check.try &.call
        fresh = dir.stat?(leaf)
        raise Error.new("Git checkout tracked symlink replaced") unless fresh && fresh.st_dev == initial.st_dev &&
                                                                        fresh.st_ino == initial.st_ino
        raise Error.new("Git checkout tracked symlink changed") unless ObjectId.digest("blob", raw, format) == old.oid
        return
      end
      raise Error.new("Git checkout tracked path disappeared") unless initial &&
                                                                      (initial.st_mode & LibC::S_IFMT) == LibC::S_IFREG
      io = dir.open_file(leaf, LibC::O_RDONLY)
      begin
        observed = io.info
        raise Error.new("Git checkout tracked leaf not regular") unless observed.type.file?
        raise Error.new("Git checkout tracked leaf too large") if observed.size > 8_388_608
        original = uninitialized LibC::Stat
        raise Error.new("Git checkout tracked inode changed") unless LibC.fstat(io.fd, pointerof(original)) == 0 &&
                                                                     original.st_ino == initial.st_ino && original.st_dev == initial.st_dev
        data = IO::Memory.new
        IO.copy(io, data, 8_388_609_i64)
        check.try &.call
        after = io.info
        raise Error.new("Git checkout tracked file changed during read") unless observed.same_file?(after) &&
                                                                                observed.size == after.size && observed.modification_time == after.modification_time &&
                                                                                observed.permissions == after.permissions && data.size == after.size
        actual_mode = after.permissions.value & 0o111 != 0 ? "100755" : "100644"
        raise Error.new("Git checkout tracked file changed") unless actual_mode == old.mode &&
                                                                    ObjectId.digest("blob", data.to_s, format) == old.oid
        fresh = dir.stat?(leaf)
        raise Error.new("Git checkout tracked leaf replaced") unless fresh && fresh.st_dev == initial.st_dev &&
                                                                     fresh.st_ino == initial.st_ino
      ensure
        io.close unless io.closed?
      end
    end
  end
end
