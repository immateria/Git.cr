require "c/fcntl"
require "c/sys/stat"
require "errno"

# Files-backend primitive: keep each pathname component beneath an
# already-open directory. This confines a parent replacement/symlink race to
# the originally opened directory; it does not make the leaf operation a
# conditional inode-atomic unlink/rename.
lib LibC
  # openat is variadic in C (its create mode rides the variadic argument
  # slot); a fixed mode parameter here passes it where the callee on Darwin
  # never looks, and the kernel creates the file with garbage permissions.
  fun openat(dirfd : Int, path : Char*, flags : Int, ...) : Int
  fun unlinkat(dirfd : Int, path : Char*, flags : Int) : Int
  fun renameat(olddirfd : Int, oldpath : Char*, newdirfd : Int, newpath : Char*) : Int
  fun fstatat(dirfd : Int, path : Char*, stat : Stat*, flags : Int) : Int
  fun mkdirat(dirfd : Int, path : Char*, mode : ModeT) : Int
  fun readlinkat(dirfd : Int, path : Char*, buffer : UInt8*, size : SizeT) : SSizeT
  fun symlinkat(target : Char*, dirfd : Int, name : Char*) : Int
  {% if flag?(:darwin) %}
    fun renameatx_np(fromfd : Int32, from : UInt8*, tofd : Int32, to : UInt8*, flags : UInt32) : Int32
  {% else %}
    fun renameat2(olddirfd : Int, oldpath : Char*, newdirfd : Int, newpath : Char*, flags : UInt32) : Int
  {% end %}
end

module Git
  module DescriptorPath
    {% if flag?(:darwin) %}
      # Darwin sys/fcntl.h: O_DIRECTORY is 0x00100000, AT_SYMLINK_NOFOLLOW is
      # 0x20 and AT_REMOVEDIR is 0x80, each distinct from Linux's value;
      # O_DIRECTORY is not exported by Crystal's bundled declarations. The
      # no-replace flag is renameatx_np's RENAME_EXCL, from sys/stdio.h.
      DIRECTORY_ONLY      = 0x00100000
      DIRECTORY_FLAGS     = LibC::O_RDONLY | LibC::O_CLOEXEC | LibC::O_NOFOLLOW | DIRECTORY_ONLY
      AT_SYMLINK_NOFOLLOW =           0x20
      AT_REMOVEDIR        =           0x80
      RENAME_NO_REPLACE   = 0x00000004_u32
    {% else %}
      # Linux: AT_SYMLINK_NOFOLLOW and AT_REMOVEDIR are the same on every
      # architecture, O_DIRECTORY is not. x86-64 takes asm-generic/fcntl.h's
      # 0o200000; arm and arm64 define 0o40000
      # (arch/arm64/include/uapi/asm/fcntl.h), where 0o200000 is O_DIRECT,
      # which a directory refuses. The no-replace flag is renameat2's
      # RENAME_NOREPLACE.
      DIRECTORY_ONLY      = {% if flag?(:aarch64) || flag?(:arm) %} 0o40000 {% else %} 0o200000 {% end %}
      DIRECTORY_FLAGS     = LibC::O_RDONLY | LibC::O_CLOEXEC | LibC::O_NOFOLLOW | DIRECTORY_ONLY
      AT_SYMLINK_NOFOLLOW =   0x100
      AT_REMOVEDIR        =   0x200
      RENAME_NO_REPLACE   = 0x1_u32
    {% end %}

    class Directory
      @fd : Int32
      @closed = false

      private def initialize(@fd : Int32)
      end

      def self.open(absolute : String) : Directory
        raise Git::Error.new("Git descriptor path must be absolute") unless absolute.starts_with?('/') && absolute.bytesize <= 16_384
        components = absolute.split('/').reject(&.empty?)
        raise Git::Error.new("Git descriptor path traversal rejected") if components.size > 128 || components.any? { |c| c == "." || c == ".." || c.includes?('\0') }
        fd = LibC.open("/", DIRECTORY_FLAGS)
        raise Git::Error.new("Git descriptor root unavailable") if fd < 0
        begin
          components.each do |component|
            next_fd = LibC.openat(fd, component, DIRECTORY_FLAGS, 0)
            raise Git::Error.new("Git descriptor parent missing or redirected: #{component}") if next_fd < 0
            LibC.close(fd)
            fd = next_fd
          end
          new(fd)
        rescue ex
          LibC.close(fd)
          raise ex
        end
      end

      def self.open_parent(absolute_file : String) : {Directory, String}
        basename = File.basename(absolute_file)
        validate_basename!(basename)
        {open(File.dirname(absolute_file)), basename}
      end

      def self.with_parent(absolute_file : String, & : Directory, String -> T) : T forall T
        dir, basename = open_parent(absolute_file)
        begin
          yield dir, basename
        ensure
          dir.close
        end
      end

      def self.validate_basename!(name : String) : Nil
        raise Git::Error.new("Git descriptor leaf name rejected") if name.empty? || name == "." || name == ".." || name.includes?('/') || name.includes?('\0') || name.bytesize > 4096
      end

      # Open a direct child relative to this pinned directory. An attacker
      # changing an ancestor cannot redirect the operation into a second
      # administrative directory during initialization.
      def self.open_child(parent : Directory, name : String) : Directory
        Directory.validate_basename!(name)
        fd = LibC.openat(parent.@fd, name, DIRECTORY_FLAGS, 0)
        raise Git::Error.new("Git descriptor child directory unavailable or redirected: #{name}") if fd < 0
        new(fd)
      end

      def open_directory(name : String) : Directory
        Directory.open_child(self, name)
      end

      def open_file(name : String, flags : Int32, mode : Int32 = 0o600) : IO::FileDescriptor
        Directory.validate_basename!(name)
        fd = LibC.openat(@fd, name, flags | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, mode)
        raise Git::Error.new("Git descriptor file unavailable or redirected: #{name}") if fd < 0
        IO::FileDescriptor.new(fd)
      end

      # The only accepted absence is ENOENT, not a symlink or permission error.
      def open_file?(name : String, flags : Int32 = LibC::O_RDONLY) : IO::FileDescriptor?
        Directory.validate_basename!(name)
        fd = LibC.openat(@fd, name, flags | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0)
        return IO::FileDescriptor.new(fd) if fd >= 0
        return nil if Errno.value == Errno::ENOENT
        raise Git::Error.new("Git descriptor file unavailable or redirected: #{name}")
      end

      def stat?(name : String) : LibC::Stat?
        Directory.validate_basename!(name)
        stat = uninitialized LibC::Stat
        result = LibC.fstatat(@fd, name, pointerof(stat), AT_SYMLINK_NOFOLLOW)
        return stat if result == 0
        return nil if Errno.value == Errno::ENOENT
        raise Git::Error.new("Git descriptor stat unavailable: #{name}")
      end

      # Inspect the stored symlink bytes without traversing its destination.
      # Refuse if the leaf inode changed before/after the read.
      def read_symlink(name : String, max_bytes : Int32) : String
        raise ArgumentError.new("invalid Git symlink byte budget") if max_bytes < 1
        before = stat?(name) || raise Git::Error.new("Git symlink missing")
        raise Git::Error.new("Git expected symlink leaf") unless (before.st_mode & LibC::S_IFMT) == LibC::S_IFLNK
        buffer = Bytes.new(max_bytes + 1)
        size = LibC.readlinkat(@fd, name, buffer.to_unsafe, buffer.size)
        raise Git::Error.new("Git symlink target unavailable or too large") if size < 0 || size > max_bytes
        after = stat?(name) || raise Git::Error.new("Git symlink disappeared")
        raise Git::Error.new("Git symlink replaced during read") unless before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
                                                                        (after.st_mode & LibC::S_IFMT) == LibC::S_IFLNK
        String.new(buffer[0, size.to_i])
      end

      def symlink_new(name : String, target : String) : LibC::Stat
        Directory.validate_basename!(name)
        raise Git::Error.new("Git symlink target invalid") if target.empty? || target.includes?('\0') || target.bytesize > 4095
        raise Git::Error.new("Git symlink creation failed") unless LibC.symlinkat(target, @fd, name) == 0
        stat?(name) || raise Git::Error.new("Git new symlink missing")
      end

      def same_stat?(name : String, before : LibC::Stat) : Bool
        after = stat?(name)
        !!after && before.st_ino == after.st_ino && before.st_dev == after.st_dev &&
          (before.st_mode & LibC::S_IFMT) == (after.st_mode & LibC::S_IFMT)
      end

      def same_inode?(name : String, io : IO::FileDescriptor) : Bool
        actual = stat?(name)
        return false unless actual
        original = uninitialized LibC::Stat
        raise Git::Error.new("Git descriptor inode unavailable") unless LibC.fstat(io.fd, pointerof(original)) == 0
        actual.st_dev == original.st_dev && actual.st_ino == original.st_ino &&
          (actual.st_mode & LibC::S_IFMT) == LibC::S_IFREG
      end

      # Detect a parent directory that became unreachable at its validated
      # pathname. Even after this check, leaf publication itself is protected
      # by the pinned descriptor rather than by a second pathname lookup.
      def attached_at?(absolute : String) : Bool
        other = Directory.open(absolute)
        begin
          initial = uninitialized LibC::Stat
          current = uninitialized LibC::Stat
          raise Git::Error.new("Git descriptor parent identity unavailable") unless LibC.fstat(@fd, pointerof(initial)) == 0 && LibC.fstat(other.@fd, pointerof(current)) == 0
          initial.st_dev == current.st_dev && initial.st_ino == current.st_ino
        ensure
          other.close
        end
      rescue Git::Error
        false
      end

      def mkdir(name : String, mode : Int32 = 0o700) : Nil
        Directory.validate_basename!(name)
        if LibC.mkdirat(@fd, name, mode) < 0
          raise Git::Error.new("Git descriptor directory creation failed: #{name}") unless Errno.value == Errno::EEXIST
        end
      end

      # Creation for new repositories must fail on EEXIST, rather than
      # silently treating an existing directory as owned by this operation.
      def mkdir_new(name : String, mode : Int32 = 0o755) : Nil
        Directory.validate_basename!(name)
        raise Git::Error.new("Git descriptor directory already exists or cannot be created: #{name}") if LibC.mkdirat(@fd, name, mode) < 0
      end

      def unlink(name : String) : Nil
        Directory.validate_basename!(name)
        raise Git::Error.new("Git descriptor unlink failed: #{name}") unless LibC.unlinkat(@fd, name, 0) == 0
      end

      def rmdir(name : String) : Nil
        Directory.validate_basename!(name)
        raise Git::Error.new("Git descriptor directory removal failed: #{name}") unless LibC.unlinkat(@fd, name, AT_REMOVEDIR) == 0
      end

      def rename(oldname : String, newname : String) : Nil
        Directory.validate_basename!(oldname)
        Directory.validate_basename!(newname)
        raise Git::Error.new("Git descriptor rename failed") unless LibC.renameat(@fd, oldname, @fd, newname) == 0
      end

      # No-replace rename: never replace a newly created untracked leaf.
      # Linux calls renameat2 with RENAME_NOREPLACE; Darwin's renameatx_np
      # with RENAME_EXCL refuses an existing destination the same way.
      def rename_noreplace(oldname : String, newname : String) : Nil
        Directory.validate_basename!(oldname)
        Directory.validate_basename!(newname)
        result = {% if flag?(:darwin) %}
                   LibC.renameatx_np(@fd, oldname, @fd, newname, RENAME_NO_REPLACE)
                 {% else %}
                   LibC.renameat2(@fd, oldname, @fd, newname, RENAME_NO_REPLACE)
                 {% end %}
        raise Git::Error.new("Git descriptor destination appeared during publication") unless result == 0
      end

      def sync : Nil
        raise Git::Error.new("Git descriptor directory fsync failed") unless LibC.fsync(@fd) == 0
      end

      def close : Nil
        return if @closed
        @closed = true
        LibC.close(@fd)
      end
    end
  end
end
