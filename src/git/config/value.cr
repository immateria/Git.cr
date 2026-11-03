module Git
  class Config
    # Pure conversion rules for Git config typed values.
    private module Value
      def self.boolean(value : String?, name : String) : Bool
        return true unless value
        return false if value.empty?
        case value.downcase
        when "true", "yes", "on"  then true
        when "false", "no", "off" then false
        else
          integer(value, name, Int32::MAX.to_i128) != 0
        end
      end

      def self.integer(value : String?, name : String, maximum : Int128) : Int64
        raise Error.new("invalid numeric Git config value for #{name}") unless raw = value
        match = /\A([+-]?)(0[xX][0-9A-Fa-f]+|0[bB][01]+|0[0-7]*|[1-9][0-9]*)([kKmMgG]?)\z/.match(raw)
        raise Error.new("invalid numeric Git config value for #{name}") unless match
        digits = match[2]
        radix = if digits.starts_with?("0x") || digits.starts_with?("0X")
                  digits = digits.byte_slice(2)
                  16
                  # Native policy is intentionally fixed across libc versions:
                  # some Git 2.47.3 builds reject binary-prefixed config ints.
                elsif digits.starts_with?("0b") || digits.starts_with?("0B")
                  digits = digits.byte_slice(2)
                  2
                elsif digits.bytesize > 1 && digits.starts_with?('0')
                  8
                else
                  10
                end
        magnitude = digits.to_i128?(radix)
        raise Error.new("invalid numeric Git config value for #{name}") unless magnitude
        scale = case match[3].downcase
                when "k" then 1_024_i128
                when "m" then 1_048_576_i128
                when "g" then 1_073_741_824_i128
                else          1_i128
                end
        # Bound before multiplication: a syntactically valid Int128 magnitude
        # with a Git size suffix must not raise an unrelated overflow exception.
        negative = match[1] == "-"
        # Git's signed integer parser bounds the unsigned magnitude before
        # applying the minus sign: INT_MIN itself is not an accepted literal.
        maximum_magnitude = maximum
        raise Error.new("numeric Git config value out of range for #{name}") if magnitude > maximum_magnitude // scale
        number = magnitude * scale * (negative ? -1_i128 : 1_i128)
        number.to_i64
      end
    end
  end
end
