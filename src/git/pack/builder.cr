module Git
  module Pack
    # Git's pack-objects: write a pack holding a chosen set of objects,
    # with trees and blobs delta-compressed against similar objects found
    # in a sliding window (sorted by type, path hash and size as Git
    # does). Bases outside the pack ("preferred bases") make a thin pack.
    class Builder
      record Stats, objects : Int32, deltas : Int32, thin_deltas : Int32, bytes : Int64, checksum : String,
        entries : Array(IndexEntry)

      # How an entry was written.
      private enum Written
        Full
        Delta
        ThinDelta
      end

      private class Candidate
        getter oid : String
        getter type : String
        getter name_hash : UInt32
        property size : Int32
        getter external : Bool
        property data : Bytes?
        property index : Delta::SourceIndex? = nil
        property base : Candidate? = nil
        property delta : Bytes? = nil
        property depth : Int32 = 0
        property offset : Int64 = -1_i64
        property order : Int32
        # Stored entry copied verbatim; with reused_delta its base is kept.
        property raw : ObjectDatabase::PackFiles::RawEntry? = nil
        property reused_delta : Bool = false

        def initialize(@oid, @type, @name_hash, @size, @external, @data, @order)
        end
      end

      def initialize(@repository : Repository, *,
                     @window : Int32 = 10,
                     @max_depth : Int32 = 50,
                     @ofs_delta : Bool = true,
                     @delta_size_limit : Int32 = 64 * 1024 * 1024,
                     @max_object_bytes : Int32 = Int32::MAX - 129,
                     @compression_level : Int32 = Compress::Zlib::DEFAULT_COMPRESSION,
                     @reuse : Bool = true,
                     @check : Proc(Nil)? = nil)
        raise ArgumentError.new("invalid Git pack window") if @window < 0 || @max_depth < 0 || @max_depth > 4095
      end

      # Git's pack_name_hash: the last characters of a path dominate, so
      # files with the same name in different directories sort together.
      def self.name_hash(path : String?) : UInt32
        return 0_u32 unless path
        hash = 0_u32
        path.each_byte do |byte|
          next if byte == 32 || (9 <= byte <= 13)
          hash = (hash >> 2) &+ (byte.to_u32 << 24)
        end
        hash
      end

      # Write items (in the given order, bases first where needed) to io.
      # preferred_bases are objects the receiver already has: they may be
      # used as REF_DELTA bases but are never written.
      def write(io : IO, items : Array(History::ReachableObject),
                preferred_bases : Array(History::ReachableObject) = [] of History::ReachableObject) : Stats
        candidates = items.map_with_index do |item, order|
          Candidate.new(item.oid, item.type, Builder.name_hash(item.path), 0, false, nil, order)
        end
        seen = items.map(&.oid).to_set
        bases = preferred_bases.compact_map do |item|
          next nil if seen.includes?(item.oid) || !{"tree", "blob"}.includes?(item.type)
          seen << item.oid
          Candidate.new(item.oid, item.type, Builder.name_hash(item.path), 0, true, nil, -1)
        end
        plan_reuse(candidates, bases) if @reuse
        find_deltas(candidates + bases) if @window > 0
        writer = Writer.new(io, @repository.object_format, candidates.size, @compression_level)
        entries = [] of IndexEntry
        deltas = 0
        thin = 0
        candidates.each do |candidate|
          write_candidate(writer, candidate, entries) do |written|
            deltas += 1 unless written.full?
            thin += 1 if written.thin_delta?
          end
        end
        checksum = writer.finish
        Stats.new(candidates.size, deltas, thin, writer.position, checksum, entries)
      end

      private def write_candidate(writer : Writer, candidate : Candidate, entries : Array(IndexEntry),
                                  &block : Written ->) : Nil
        return if candidate.offset >= 0
        @check.try &.call
        if raw = candidate.raw
          data = @repository.pack_files.raw_data(raw)
          base = candidate.base
          if candidate.reused_delta && base
            if base.external
              offset, crc = writer.write_raw(EntryType::RefDelta, raw.header.size, data, base_oid: base.oid)
              block.call(Written::ThinDelta)
            else
              write_candidate(writer, base, entries, &block) if base.offset < 0
              offset, crc = if @ofs_delta
                              writer.write_raw(EntryType::OfsDelta, raw.header.size, data, base_offset: base.offset)
                            else
                              writer.write_raw(EntryType::RefDelta, raw.header.size, data, base_oid: base.oid)
                            end
              block.call(Written::Delta)
            end
          else
            offset, crc = writer.write_raw(raw.header.type, raw.header.size, data)
            block.call(Written::Full)
          end
          candidate.offset = offset
          entries << IndexEntry.new(candidate.oid, offset, crc)
          return
        end
        if (base = candidate.base) && (delta = candidate.delta)
          if base.external
            offset, crc = writer.write_ref_delta(base.oid, delta)
            block.call(Written::ThinDelta)
          else
            write_candidate(writer, base, entries, &block) if base.offset < 0
            offset, crc = if @ofs_delta
                            writer.write_ofs_delta(base.offset, delta)
                          else
                            writer.write_ref_delta(base.oid, delta)
                          end
            block.call(Written::Delta)
          end
        else
          kind, raw = @repository.object(candidate.oid, @max_object_bytes) { @check.try &.call }
          raise Error.new("Git object #{candidate.oid} type changed while packing") unless kind == candidate.type
          offset, crc = writer.write_object(kind, raw.to_slice)
          block.call(Written::Full)
        end
        candidate.offset = offset
        entries << IndexEntry.new(candidate.oid, offset, crc)
      end

      # Reuse stored entries: undeltified ones as they are, deltas whose
      # base is also being written (or is a preferred base of a thin pack).
      private def plan_reuse(candidates : Array(Candidate), bases : Array(Candidate)) : Nil
        by_oid = {} of String => Candidate
        candidates.each { |candidate| by_oid[candidate.oid] = candidate }
        external = {} of String => Candidate
        bases.each { |candidate| external[candidate.oid] = candidate }
        candidates.each do |candidate|
          @check.try &.call
          entry = @repository.pack_files.raw_entry(candidate.oid) || next
          if !entry.header.type.delta?
            next unless entry.header.type.object_type == candidate.type
            candidate.raw = entry
          elsif base_oid = entry.base_oid
            base = by_oid[base_oid]? || external[base_oid]?
            next unless base && base != candidate
            candidate.raw = entry
            candidate.base = base
            candidate.reused_delta = true
          end
        end
      end

      # Sliding-window delta search over trees and blobs.
      private def find_deltas(all : Array(Candidate)) : Nil
        # Reused deltas neither take new deltas nor serve as bases.
        list = all.select { |candidate| (candidate.type == "tree" || candidate.type == "blob") && !candidate.reused_delta }
        list.each do |candidate|
          @check.try &.call
          _, size = @repository.object_header(candidate.oid) { @check.try &.call }
          candidate.size = size.clamp(0_i64, Int32::MAX.to_i64).to_i32
        end
        list.sort! do |a, b|
          comparison = (a.type == b.type ? 0 : (a.type == "tree" ? -1 : 1))
          comparison = b.name_hash <=> a.name_hash if comparison == 0
          # Preferred bases come first so that new objects can use them.
          comparison = (a.external == b.external ? 0 : (a.external ? -1 : 1)) if comparison == 0
          comparison = b.size <=> a.size if comparison == 0
          comparison
        end
        window = Deque(Candidate).new
        list.each do |target|
          @check.try &.call
          data = load(target)
          if data && !target.external && target.raw.nil? && target.size >= 32 && target.size <= @delta_size_limit
            best_size = (target.size // 2 - @repository.object_format.bytesize).to_i64
            window.each do |base|
              next unless base.type == target.type
              # A reused delta keeps its stored base; basing a new delta on
              # it could close a cycle through that base.
              next if base.reused_delta
              next if base.depth >= @max_depth
              next if base.size < target.size // 32 || target.size < base.size // 32
              source = base.data || next
              limit = base.delta ? best_size * (@max_depth - base.depth) // (@max_depth + 1) : best_size
              next if limit <= 0
              index = base.index ||= Delta::SourceIndex.new(source)
              if encoded = index.encode(data, limit)
                if encoded.size < best_size
                  best_size = encoded.size.to_i64
                  target.base = base
                  target.delta = encoded
                  target.depth = base.depth + 1
                end
              end
            end
          end
          window.push(target)
          if window.size > @window
            evicted = window.shift
            evicted.data = nil
            evicted.index = nil
          end
        end
        window.each do |candidate|
          candidate.data = nil
          candidate.index = nil
        end
        # A base chosen later in the window may itself have been given a
        # delta afterwards; deltas never form cycles because each target's
        # base was earlier in the sorted list.
      end

      private def load(candidate : Candidate) : Bytes?
        return nil if candidate.size > @delta_size_limit
        _, raw = @repository.object(candidate.oid, @max_object_bytes) { @check.try &.call }
        bytes = raw.to_slice
        candidate.data = bytes
        bytes
      end
    end
  end
end
