require "../../tree_diff/similarity"

module Git
  struct Merge
    # :nodoc:
    # Match edited renames using shared content similarity, enforcing merge's
    # object read and comparison budgets and deterministic candidate ranking.
    class Similarity
      MAX_PAIRS = 1_000_000
      @similarity : TreeDiff::Similarity
      @bytes = 0_i64
      @pairs = 0

      def initialize(@repository : Repository, @max_object_bytes : Int32,
                     @max_total_bytes : Int64, @check : Proc(Nil)?)
        @similarity = TreeDiff::Similarity.new(@check) do |oid|
          kind, raw = @repository.object(oid, @max_object_bytes) { @check.try &.call }
          raise Error.new("Git rename similarity expected blob") unless kind == "blob"
          @bytes += raw.bytesize
          raise Error.new("Git rename similarity byte budget exceeded") if @bytes > @max_total_bytes
          raw
        end
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
        @similarity.score(left.oid, right.oid)
      end
    end
  end
end
