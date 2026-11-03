module Git
  class Remote
    # A Git refspec: [+]<src>[:<dst>], ^<src> for an exclusion, with at most
    # one "*" in each side of a pattern.
    struct Refspec
      getter source : String
      getter destination : String?
      getter? force : Bool
      getter? negative : Bool
      getter? pattern : Bool

      def initialize(@source : String, @destination : String?, @force : Bool = false,
                     @negative : Bool = false, @pattern : Bool = false)
      end

      # Parse a fetch (or, with fetch: false, a push) refspec.
      def self.parse(text : String, *, fetch : Bool = true) : Refspec
        raise Error.new("empty Git refspec") if text.empty?
        rest = text
        force = false
        negative = false
        if rest.starts_with?('+')
          force = true
          rest = rest.byte_slice(1)
        elsif rest.starts_with?('^')
          negative = true
          rest = rest.byte_slice(1)
        end
        source, separator, destination = rest.rpartition(':')
        if separator.empty?
          source = rest
          destination = nil
        end
        if negative
          raise Error.new("negative Git refspec cannot have a destination") if destination
          raise Error.new("negative Git refspec needs a source") if source.empty?
        end
        source_star = source.count('*')
        destination_star = destination.try(&.count('*')) || 0
        raise Error.new("invalid Git refspec #{text.inspect}: more than one '*'") if source_star > 1 || destination_star > 1
        pattern = source_star == 1
        if destination && !destination.empty? && (source_star != destination_star)
          raise Error.new("invalid Git refspec #{text.inspect}: '*' must appear on both sides")
        end
        if fetch
          raise Error.new("invalid Git fetch refspec #{text.inspect}") if source.empty? && !(destination.nil? || destination.empty?)
        else
          raise Error.new("invalid Git push refspec #{text.inspect}") if source.empty? && (destination.nil? || destination.empty?) && !text.starts_with?(':')
        end
        validate_side!(source, text) unless source.empty? || source == "@" || object_id?(source)
        validate_side!(destination.not_nil!, text) if destination && !destination.empty?
        new(source, destination.try { |value| value.empty? ? nil : value }, force, negative, pattern)
      end

      def self.object_id?(text : String) : Bool
        (text.bytesize == 40 || text.bytesize == 64) && text.each_byte.all? { |byte| (48 <= byte <= 57) || (97 <= byte <= 102) }
      end

      private def self.validate_side!(side : String, text : String) : Nil
        probe = side.sub('*', "x")
        candidate = probe.starts_with?("refs/") || probe == "HEAD" ? probe : "refs/heads/#{probe}"
        raise Error.new("invalid Git refspec #{text.inspect}") unless candidate == "HEAD" || RefName.valid?(candidate)
      end

      # Whether name matches the source side.
      def source_matches?(name : String) : Bool
        Refspec.matches?(@source, name, @pattern)
      end

      # The destination for a source name, or nil if it does not match or
      # the refspec stores nothing.
      def map_source(name : String) : String?
        return nil unless source_matches?(name)
        destination = @destination || return nil
        return destination unless @pattern
        star = @source.index('*').not_nil!
        middle = name.byte_slice(star, name.bytesize - (@source.bytesize - 1))
        destination.sub('*', middle)
      end

      # The source for a destination name (used for pruning).
      def map_destination(name : String) : String?
        destination = @destination || return nil
        return nil unless Refspec.matches?(destination, name, @pattern)
        return @source unless @pattern
        star = destination.index('*').not_nil!
        middle = name.byte_slice(star, name.bytesize - (destination.bytesize - 1))
        @source.sub('*', middle)
      end

      def self.matches?(side : String, name : String, pattern : Bool) : Bool
        return side == name unless pattern
        star = side.index('*').not_nil!
        prefix = side.byte_slice(0, star)
        suffix = side.byte_slice(star + 1)
        name.bytesize >= prefix.bytesize + suffix.bytesize && name.starts_with?(prefix) && name.ends_with?(suffix)
      end

      def to_s(io : IO) : Nil
        io << '+' if @force
        io << '^' if @negative
        io << @source
        if destination = @destination
          io << ':' << destination
        end
      end
    end
  end
end
