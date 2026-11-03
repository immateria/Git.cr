module Git
  # Normal refname grammar equivalent to `git check-ref-format` without
  # --allow-onelevel/--refspec-pattern/--branch flags. This validates bytes,
  # not a Unicode string or an executable command-line argument. The reader
  # additionally requires refs/ names for loose-ref filesystem access.
  module RefName
    def self.valid?(name : String) : Bool
      return false if name.empty? || name == "@" || name.ends_with?('.') || name.ends_with?('/')
      return false if name.includes?("..") || name.includes?("@{")
      separator = false
      component_start = 0
      name.bytesize.times do |i|
        byte = name.byte_at(i)
        return false if byte <= 32 || byte == 127 || {92, 126, 94, 58, 63, 42, 91}.includes?(byte.to_i)
        if byte == 47
          return false unless valid_component?(name, component_start, i)
          component_start = i + 1
          separator = true
        end
      end
      separator && valid_component?(name, component_start, name.bytesize)
    end

    def self.valid!(name : String) : String
      raise Error.new("Git reference name rejected") unless valid?(name)
      name
    end

    private def self.valid_component?(name : String, start : Int32, finish : Int32) : Bool
      return false if finish <= start || name.byte_at(start) == 46
      # Git rejects the literal case-sensitive suffix `.lock` on components.
      return false if finish - start >= 5 && name.byte_slice(finish - 5, 5) == ".lock"
      true
    end
  end
end
