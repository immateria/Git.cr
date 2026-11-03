module Git
  class Repository
    # `git pack-refs --all` (or, without all, tags and already-packed refs):
    # write every direct ref with peeled tag values into packed-refs, then
    # remove the loose files that still hold the packed values.
    protected def pack_refs(*, all : Bool = true, prune : Bool = true, check : Proc(Nil)? = nil) : Int32
      check!
      path = File.join(@common, "packed-refs")
      lock = path + ".lock"
      fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o644)
      raise Error.new("Git packed-refs.lock exists or cannot be created") if fd < 0
      packed_before = Set(String).new
      if File.file?(path)
        File.each_line(path) do |line|
          next if line.starts_with?('#') || line.starts_with?('^') || line.empty?
          packed_before << line.split(' ', 2)[1]
        end
      end
      selected = references("refs/").reject(&.symbolic?).select do |ref|
        all || ref.name.starts_with?("refs/tags/") || packed_before.includes?(ref.name)
      end
      walker = History::RevisionWalker.new(self, check: check)
      loose = [] of References::Ref
      begin
        io = IO::FileDescriptor.new(fd)
        begin
          io << "# pack-refs with: peeled fully-peeled sorted \n"
          selected.each do |ref|
            check.try &.call
            oid = ref.oid.not_nil!
            io << oid << ' ' << ref.name << '\n'
            if has_object?(oid) && object_header(oid).type.tag?
              io << '^' << walker.peel(oid)[1] << '\n'
            end
            loose << ref if File.file?(File.join(@common, ref.name))
          end
          io.flush
          io.fsync
        ensure
          io.close
        end
        File.rename(lock, path)
        lock = nil
      ensure
        lock.try { |stale| File.delete?(stale) }
      end
      if prune
        loose.each { |ref| prune_loose_ref(ref) }
      end
      selected.size
    end

    # Remove a loose ref file under its lock if it still holds the value
    # that was packed, then empty parent directories below refs/<kind>/.
    private def prune_loose_ref(ref : References::Ref) : Nil
      file = File.join(@common, ref.name)
      lock = file + ".lock"
      fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o644)
      return if fd < 0
      begin
        LibC.close(fd)
        current = File.read(file).strip rescue nil
        File.delete?(file) if current == ref.oid
      ensure
        File.delete?(lock)
      end
      directory = File.dirname(file)
      stop = File.join(@common, "refs")
      while directory.starts_with?(stop + "/") && directory.count('/') > stop.count('/') + 1 && Dir.exists?(directory) && Dir.empty?(directory)
        Dir.delete(directory)
        directory = File.dirname(directory)
      end
    end
  end
end
