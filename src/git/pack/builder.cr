module Git
  module Pack
    # Git's pack-objects: write a pack holding a chosen set of objects,
    # with trees and blobs delta-compressed against similar objects found
    # in a sliding window (sorted by type, path hash and size as Git
    # does). Bases outside the pack ("preferred bases") make a thin pack.
    class Builder
      record Stats, objects : Int32, deltas : Int32, thin_deltas : Int32, bytes : Int64, checksum : String,
        entries : Array(Entry)

      private class Candidate
        getter oid : String
        getter type : String
        getter name_hash : UInt32
        property size : Int32
        getter external : Bool
        property data : Bytes?
        property index : Delta::Index? = nil
        property base : Candidate? = nil
        property delta : Bytes? = nil
        property depth : Int32 = 0
        property offset : Int64 = -1_i64
        property order : Int32

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
      def write(io : IO, items : Array(Reachability::Item),
                preferred_bases : Array(Reachability::Item) = [] of Reachability::Item) : Stats
        candidates = items.map_with_index do |item, order|
          Candidate.new(item.oid, item.type, Builder.name_hash(item.path), 0, false, nil, order)
        end
        seen = items.map(&.oid).to_set
        bases = preferred_bases.compact_map do |item|
          next nil if seen.includes?(item.oid) || !{"tree", "blob"}.includes?(item.type)
          seen << item.oid
          Candidate.new(item.oid, item.type, Builder.name_hash(item.path), 0, true, nil, -1)
        end
        find_deltas(candidates + bases) if @window > 0
        writer = Writer.new(io, @repository.object_format, candidates.size, @compression_level)
        entries = [] of Entry
        deltas = 0
        thin = 0
        candidates.each do |candidate|
          write_candidate(writer, candidate, entries) do |kind|
            deltas += 1 unless kind == :full
            thin += 1 if kind == :thin
          end
        end
        checksum = writer.finish
        Stats.new(candidates.size, deltas, thin, writer.position, checksum, entries)
      end

      private def write_candidate(writer : Writer, candidate : Candidate, entries : Array(Entry),
                                  &block : Symbol ->) : Nil
        return if candidate.offset >= 0
        @check.try &.call
        if (base = candidate.base) && (delta = candidate.delta)
          if base.external
            offset, crc = writer.write_ref_delta(base.oid, delta)
            block.call(:thin)
          else
            write_candidate(writer, base, entries, &block) if base.offset < 0
            offset, crc = if @ofs_delta
                            writer.write_ofs_delta(base.offset, delta)
                          else
                            writer.write_ref_delta(base.oid, delta)
                          end
            block.call(:delta)
          end
        else
          kind, raw = @repository.object(candidate.oid, @max_object_bytes) { @check.try &.call }
          raise Error.new("Git object #{candidate.oid} type changed while packing") unless kind == candidate.type
          offset, crc = writer.write_object(kind, raw.to_slice)
          block.call(:full)
        end
        candidate.offset = offset
        entries << Entry.new(candidate.oid, offset, crc)
      end

      # Sliding-window delta search over trees and blobs.
      private def find_deltas(all : Array(Candidate)) : Nil
        list = all.select { |candidate| candidate.type == "tree" || candidate.type == "blob" }
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
          if data && !target.external && target.size >= 32 && target.size <= @delta_size_limit
            best_size = (target.size // 2 - @repository.object_format.bytesize).to_i64
            window.each do |base|
              next unless base.type == target.type
              next if base.depth >= @max_depth
              next if base.size < target.size // 32 || target.size < base.size // 32
              source = base.data || next
              limit = base.delta ? best_size * (@max_depth - base.depth) // (@max_depth + 1) : best_size
              next if limit <= 0
              index = base.index ||= Delta::Index.new(source)
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
