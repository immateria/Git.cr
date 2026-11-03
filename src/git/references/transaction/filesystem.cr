module Git
  module References
    class Transaction
      private def self.read_small_ref(path : String) : String
        bytes = IO::Memory.new
        File.open(path) { |io| IO.copy(io, bytes, 4097) }
        raise Error.new("Git reference too large") if bytes.size > 4096
        bytes.to_s
      end

      private def self.append_log(base : String, relative : String, line : String) : Nil
        directory = base
        (["logs"] + relative.split('/')[0...-1]).each do |part|
          directory = File.join(directory, part)
          ensure_real_directory!(directory)
        end
        target = File.join(base, "logs", relative)
        raise Error.new("Git reflog symlink refused") if File.symlink?(target)
        fd = LibC.open(target, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_APPEND | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o666)
        raise Error.new("Git reflog append unavailable") if fd < 0
        io = IO::FileDescriptor.new(fd)
        begin
          io.write(line.to_slice)
          io.flush
          io.fsync
        ensure
          io.close
        end
      end

      private def self.ensure_real_directory!(path : String) : Nil
        unless Dir.exists?(path)
          raise Error.new("Git ref directory symlink refused") if File.symlink?(path) || File.exists?(path)
          begin
            Dir.mkdir(path)
          rescue ex : File::Error
            raise Error.new("Git ref directory creation failed: #{ex.class}") unless Dir.exists?(path)
          end
        end
        raise Error.new("Git ref directory redirected") if File.symlink?(path) || File.realpath(path) != path
      end
    end
  end
end
