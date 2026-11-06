module Git
  # Git tree/index names are opaque byte sequences, not UTF-8 text. String
  # serves as the immutable byte container at existing public APIs: callers
  # must not normalize, case-fold, replace invalid UTF-8, or JSON-encode the
  # raw value without an explicit presentation boundary.
  struct PathBytes
    getter raw : String

    def initialize(raw : String)
      @raw = raw.dup
    end

    def hex : String
      @raw.to_slice.hexstring
    end

    def utf8? : Bool
      @raw.valid_encoding?
    end

    # Git's usual core.quotePath=true C-style presentation, kept entirely
    # separate from the raw bytes used for index/tree lookups and filesystem
    # operations. This is not a filesystem path decoder or an authorization.
    def display : String
      self.class.quote(@raw)
    end

    def self.quote(raw : String) : String
      needs_quotes = raw.each_byte.any? { |byte| byte < 32 || byte >= 127 || byte == 34 || byte == 92 }
      return raw unless needs_quotes
      String.build do |builder|
        builder << '"'
        raw.each_byte do |byte|
          case byte
          when  7 then builder << "\\a"
          when  8 then builder << "\\b"
          when  9 then builder << "\\t"
          when 10 then builder << "\\n"
          when 11 then builder << "\\v"
          when 12 then builder << "\\f"
          when 13 then builder << "\\r"
          when 34 then builder << "\\\""
          when 92 then builder << "\\\\"
          else
            if byte < 32 || byte >= 127
              builder << '\\' << byte.to_s(8).rjust(3, '0')
            else
              builder << byte.chr
            end
          end
        end
        builder << '"'
      end
    end

    # JSON strings must be UTF-8. Preserve the byte identity separately as
    # raw hex for filenames that cannot be expressed as JSON strings.
    def self.json_display(raw : String) : String
      raw.valid_encoding? ? raw : quote(raw)
    end

    def self.validate_tree_name!(name : String) : Nil
      raise Error.new("invalid Git tree entry name") if name.empty? || name == "." || name == ".." ||
                                                        name.includes?('/') || name.includes?('\0')
    end

    # Repository-relative paths with conservative worktree safety checks.
    # Exact bytes are preserved, including backslash, whitespace and invalid
    # UTF-8 on POSIX. Windows path interpretation needs its own host policy.
    def self.validate_relative!(raw : String, *, max_bytes : Int32 = 4096, max_depth : Int32 = 24) : Nil
      raise Error.new("unsafe Git index path") if raw.empty? || raw.bytesize > max_bytes || raw.includes?('\0')
      parts = raw.split('/')
      raise Error.new("unsafe Git index path") if parts.size > max_depth || parts.any? do |part|
                                                    part.empty? || part == "." || part == ".." || dot_git?(part)
                                                  end
    end

    private def self.dot_git?(component : String) : Bool
      component.bytesize == 4 && component.byte_at(0) == 46 &&
        (component.byte_at(1) | 32) == 103 &&
        (component.byte_at(2) | 32) == 105 &&
        (component.byte_at(3) | 32) == 116
    end
  end
end
