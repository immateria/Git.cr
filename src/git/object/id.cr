require "digest/sha1"
require "digest/sha256"

module Git
  # Canonical object IDs and checksums for either Git repository hash format.
  # The format is repository metadata, never inferred from a caller-supplied
  # object name. Keep 40-character SHA-1 as the default of legacy helpers.
  module ObjectId
    enum Format
      SHA1
      SHA256

      def bytesize : Int32
        self == SHA1 ? 20 : 32
      end

      def hexsize : Int32
        bytesize * 2
      end
    end

    # The all-zero ID Git uses for "no object" (a ref that does not exist
    # yet, in reflogs and push commands).
    def self.zero(format : Format) : String
      "0" * format.hexsize
    end

    def self.valid!(oid : String, format : Format = Format::SHA1) : String
      unless oid.bytesize == format.hexsize && oid.each_byte.all? { |byte| (48 <= byte <= 57) || (97 <= byte <= 102) }
        raise Git::Error.new("unsupported Git OID (#{format == Format::SHA1 ? "SHA-1" : "SHA-256"} required)")
      end
      oid
    end

    def self.checksum(data : String, format : Format = Format::SHA1) : String
      case format
      in .sha1?   then Digest::SHA1.hexdigest(data)
      in .sha256? then Digest::SHA256.hexdigest(data)
      end
    end

    def self.digest(type : String, data : String, format : Format = Format::SHA1) : String
      digest(type, data.to_slice, format)
    end

    # Hash the canonical Git object envelope without copying an arbitrary
    # binary payload into a second string.
    def self.digest(type : String, data : Bytes, format : Format = Format::SHA1) : String
      header = "#{type} #{data.size}\0"
      case format
      in .sha1?   then Digest::SHA1.hexdigest { |hash| hash.update(header); hash.update(data) }
      in .sha256? then Digest::SHA256.hexdigest { |hash| hash.update(header); hash.update(data) }
      end
    end
  end
end
