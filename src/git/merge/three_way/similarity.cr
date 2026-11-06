module Git
  struct Merge
    # :nodoc:
    # Git's content similarity counts shared bytes in line/64-byte spans,
    # including repeated spans. Cache signatures across both sides, enforce
    # read and comparison budgets, and poll cancellation during large blobs.
    class Similarity
      MAX_PAIRS = 1_000_000
      record Signature, size : Int32, spans : Hash(UInt32, Int64)
      @cache = {} of String => Signature
      @bytes = 0_i64
      @pairs = 0

      def initialize(@repository : Repository, @max_object_bytes : Int32,
                     @max_total_bytes : Int64, @check : Proc(Nil)?)
      end

      def find(base : Hash(String, Checkout::FileState), side : Hash(String, Checkout::FileState),
               exact : Hash(String, String), opposite : Hash(String, Checkout::FileState)) : Hash(String, String)
        removed = base.keys.reject { |path| side.has_key?(path) || exact.has_key?(path) }.sort
        destinations = exact.values.to_set
        added = side.keys.reject { |path| base.has_key?(path) || destinations.includes?(path) }.sort
        moves = exact.dup
        return moves if removed.empty? || added.empty?
        # Keep only the four best source candidates for each destination,
        # matching Git's bounded candidate selection before greedy assignment.
        candidates = [] of {Int32, Int32, Int32, String, String}
        added.each do |dest|
          next unless regular?(side[dest])
          best = [] of {Int32, Int32, Int32, String, String}
          removed.each do |old|
            @check.try &.call
            next unless regular?(base[old])
            @pairs += 1
            raise Error.new("Git rename similarity comparison budget exceeded") if @pairs > MAX_PAIRS
            score = score(base[old], side[dest])
            next if score < 30_000
            same_name = File.basename(old) == File.basename(dest) ? 1 : 0
            relevant = opposite[old]? != base[old] ? 1 : 0
            best << {-score, -same_name, -relevant, old, dest}
            best.sort!
            best.pop if best.size > 4
          end
          candidates.concat(best)
        end
        candidates.sort!.each do |_score, _name, _relevant, old, dest|
          next if moves.has_key?(old) || destinations.includes?(dest)
          moves[old] = dest
          destinations.add(dest)
        end
        moves
      end

      private def regular?(state : Checkout::FileState) : Bool
        {"100644", "100755"}.includes?(state.mode)
      end

      private def score(left : Checkout::FileState, right : Checkout::FileState) : Int32
        a = signature(left.oid)
        b = signature(right.oid)
        size = {a.size, b.size}.max.to_i64
        return 0 if size == 0 || size - {a.size, b.size}.min > size // 2
        copied = a.spans.sum(0_i64) { |hash, count| {count, b.spans[hash]? || 0_i64}.min }
        (copied * 60_000 // size).to_i
      end

      private def signature(oid : String) : Signature
        @cache[oid] ||= begin
          kind, raw = @repository.object(oid, @max_object_bytes) { @check.try &.call }
          raise Error.new("Git rename similarity expected blob") unless kind == "blob"
          @bytes += raw.bytesize
          raise Error.new("Git rename similarity byte budget exceeded") if @bytes > @max_total_bytes
          spans = Hash(UInt32, Int64).new(0_i64)
          bytes = raw.to_slice
          text = !bytes[0, {bytes.size, 8000}.min].includes?(0_u8)
          first = 0_u32
          second = 0_u32
          length = 0
          bytes.each_with_index do |byte, index|
            @check.try &.call if index % 4096 == 0
            next if text && byte == 13 && bytes[index + 1]? == 10
            previous = first
            first = ((first << 7) ^ (second >> 25)) &+ byte.to_u32
            second = (second << 7) ^ (previous >> 25)
            length += 1
            if length == 64 || byte == 10
              spans[(first &+ (second &* 97_u32)) % 107927_u32] += length
              first = second = 0_u32
              length = 0
            end
          end
          spans[(first &+ (second &* 97_u32)) % 107927_u32] += length if length > 0
          Signature.new(raw.bytesize, spans)
        end
      end
    end
  end
end
