require "set"

module Git
  record RepackResult, pack : Pack::Received?, objects : Int32, removed_packs : Array(String),
    pruned_loose : Int32

  record GcResult, packed_refs : Int32, repack : RepackResult

  class Repository
    # Objects Git keeps when repacking: everything reachable from refs,
    # HEAD, reflog entries and the index.
    private def keep_tips : Array(String)
      tips = references("refs/").compact_map(&.oid)
      head[1].try { |oid| tips << oid }
      logs = File.join(@common, "logs")
      if Dir.exists?(logs)
        Dir.glob(File.join(logs, "**", "*")).each do |path|
          next unless File.file?(path)
          File.each_line(path) do |line|
            fields = line.split(' ', 3)
            next unless fields.size >= 2
            fields.first(2).each do |oid|
              next if oid.each_char.all? { |c| c == '0' }
              tips << oid if oid.bytesize == @object_format.hexsize && has_object?(oid)
            end
          end
        end
      end
      if File.exists?(File.join(@git_dir, "index"))
        @index.entries(Int32::MAX // 2) { nil }.each do |entry|
          tips << entry.oid if entry.mode != "160000" && has_object?(entry.oid)
        end
      end
      tips.uniq
    end

    # `git repack -a -d`: write every kept object (see keep_tips) into one
    # new pack, reusing stored deltas, then (with delete_old) remove the
    # packs it replaces and (with prune_loose) loose objects it now holds.
    # Packs with a .keep file are left alone. Unreachable objects that
    # were only in removed packs are dropped, as with Git.
    def repack(*, delete_old : Bool = true, prune_loose : Bool = true,
               window : Int32 = 10, depth : Int32 = 50,
               check : Proc(Nil)? = nil) : RepackResult
      check!
      directory = File.join(@common, "objects", "pack")
      Dir.mkdir_p(directory)
      before = Dir.children(directory).select { |name| name.ends_with?(".idx") }.map { |name| name.rchop(".idx") }
      kept = before.select { |stem| File.exists?(File.join(directory, stem + ".keep")) }
      items = reachable_objects(keep_tips, check: check)
      temp = File.join(directory, "tmp_repack_#{Random::Secure.hex(8)}")
      received = nil.as(Pack::Received?)
      begin
        File.open(temp, "wb+") do |file|
          Pack::Builder.new(self, window: window, max_depth: depth, check: check).write(file, items)
          file.flush
          file.rewind
          # Every object came from this repository: no collision checks.
          received = receive_pack(file, fix_thin: false, check_collisions: false, check: check)
        end
      ensure
        File.delete?(temp)
      end
      removed = [] of String
      new_stem = received.try(&.checksum).try { |sum| "pack-#{sum}" }
      if delete_old
        (before - kept).each do |stem|
          next if stem == new_stem
          # The index goes first so no reader finds it without its pack.
          [".idx", ".pack", ".rev", ".bitmap", ".promisor"].each do |extension|
            File.delete?(File.join(directory, stem + extension))
          end
          removed << stem
        end
        @object_database.refresh_packs
      end
      pruned = prune_loose ? prune_packed(check: check) : 0
      RepackResult.new(received, items.size, removed, pruned)
    end

    # `git prune-packed`: remove loose objects that a pack also holds.
    def prune_packed(*, check : Proc(Nil)? = nil) : Int32
      check!
      objects = File.join(@common, "objects")
      removed = 0
      @object_database.refresh_packs
      Dir.each_child(objects) do |fanout|
        next unless fanout.bytesize == 2 && fanout.each_char.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) }
        directory = File.join(objects, fanout)
        next if File.symlink?(directory) || !Dir.exists?(directory)
        Dir.children(directory).each do |rest|
          check.try &.call
          next unless rest.bytesize == @object_format.hexsize - 2
          oid = fanout + rest
          next unless @object_database.pack_files.contains?(oid)
          File.delete(File.join(directory, rest))
          removed += 1
        end
        Dir.delete(directory) if Dir.empty?(directory)
      end
      removed
    end

    # `git pack-refs --all` (or, without all, tags and already-packed refs):
    # write every direct ref with peeled tag values into packed-refs, then
    # remove the loose files that still hold the packed values.
    def pack_refs(*, all : Bool = true, prune : Bool = true, check : Proc(Nil)? = nil) : Int32
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
      walker = Reachability::Walker.new(self, check: check)
      loose = [] of References::Ref
      begin
        io = IO::FileDescriptor.new(fd)
        begin
          io << "# pack-refs with: peeled fully-peeled sorted \n"
          selected.each do |ref|
            check.try &.call
            oid = ref.oid.not_nil!
            io << oid << ' ' << ref.name << '\n'
            if has_object?(oid) && object_header(oid)[0] == "tag"
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

    # `git gc` without pruning unreachable loose objects: pack refs, repack
    # into one pack and remove loose objects that are packed.
    def gc(*, check : Proc(Nil)? = nil) : GcResult
      packed = pack_refs(check: check)
      GcResult.new(packed, repack(check: check))
    end
  end
end
