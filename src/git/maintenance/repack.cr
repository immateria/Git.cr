require "set"

module Git
  # `git repack -a -d`.
  module Repack
    # The pack written (nil when there was nothing to pack), how many
    # objects it holds, the packs it replaced and the loose objects removed.
    record Result, pack : Pack::Published?, objects : Int32, removed_packs : Array(String),
      pruned_loose : Int32
  end

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
               check : Proc(Nil)? = nil) : Repack::Result
      check!
      directory = File.join(@common, "objects", "pack")
      Dir.mkdir_p(directory)
      before = Dir.children(directory).select { |name| name.ends_with?(".idx") }.map { |name| name.rchop(".idx") }
      kept = before.select { |stem| File.exists?(File.join(directory, stem + ".keep")) }
      items = reachable_objects(keep_tips, check: check)
      temp = File.join(directory, "tmp_repack_#{Random::Secure.hex(8)}")
      published = nil.as(Pack::Published?)
      begin
        File.open(temp, "wb+") do |file|
          Pack::Builder.new(self, window: window, max_depth: depth, check: check).write(file, items)
          file.flush
          file.rewind
          # Every object came from this repository: no collision checks.
          published = index_pack(file, fix_thin: false, check_collisions: false, check: check)
        end
      ensure
        File.delete?(temp)
      end
      removed = [] of String
      new_stem = published.try(&.checksum).try { |sum| "pack-#{sum}" }
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
      Repack::Result.new(published, items.size, removed, pruned)
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
  end
end
