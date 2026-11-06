module Git
  module TreeDiff
    # :nodoc:
    # Git's content similarity counts shared bytes in line/64-byte spans,
    # including repeated spans. The reader owns object validation and read
    # budgets; signatures are cached by OID across both sides.
    class Similarity
      record Signature, size : Int32, spans : Hash(UInt32, Int64)
      @cache = {} of String => Signature
      @read : Proc(String, String)

      def initialize(@check : Proc(Nil)? = nil, &read : String -> String)
        @read = read
      end

      def score(left_oid : String, right_oid : String) : Int32
        a = signature(left_oid)
        b = signature(right_oid)
        size = {a.size, b.size}.max.to_i64
        return 0 if size == 0 || size - {a.size, b.size}.min > size // 2
        copied = a.spans.sum(0_i64) { |hash, count| {count, b.spans[hash]? || 0_i64}.min }
        (copied * 60_000 // size).to_i
      end

      private def signature(oid : String) : Signature
        @cache[oid] ||= begin
          raw = @read.call(oid)
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
