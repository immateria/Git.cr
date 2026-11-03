require "digest/sha1"
require "digest/sha256"

module Git
  # Git's pack format: the stream of entries Git transfers and stores in
  # objects/pack, with its .idx and .rev companions. Reading packs stored in
  # a repository is ObjectDatabase::PackFiles; this module owns the format
  # and the writers, the indexer and the builder.
  module Pack
    SIGNATURE = "PACK".to_slice

    # The type field of a pack entry.
    enum EntryType
      Commit   = 1
      Tree     = 2
      Blob     = 3
      Tag      = 4
      OfsDelta = 6
      RefDelta = 7

      def self.from_code(code : Int32) : EntryType
        from_value?(code) || raise Git::Error.new("unsupported Git pack entry type #{code}")
      end

      # The entry type that stores an undeltified object of this type.
      def self.for_object(type : ObjectType) : EntryType
        case type
        in .commit? then Commit
        in .tree?   then Tree
        in .blob?   then Blob
        in .tag?    then Tag
        end
      end

      def delta? : Bool
        ofs_delta? || ref_delta?
      end

      # The object type an undeltified entry stores.
      def object_type : ObjectType
        case self
        in .commit? then ObjectType::Commit
        in .tree?   then ObjectType::Tree
        in .blob?   then ObjectType::Blob
        in .tag?    then ObjectType::Tag
        in .ofs_delta?, .ref_delta?
          raise Git::Error.new("a Git delta entry has no object type of its own")
        end
      end
    end

    # The header of a pack entry: its type, declared (inflated) size and
    # delta base (an absolute offset for OFS_DELTA, an object ID for
    # REF_DELTA), and where its compressed data starts.
    record EntryHeader, type : EntryType, size : Int64, base_offset : Int64?, base_oid : String?,
      data_offset : Int64 do
      # Read the header of the entry that starts at offset.
      def self.read(io : IO, offset : Int64, hash_size : Int32) : EntryHeader
        b = io.read_byte || raise Git::Error.new("truncated Git pack object")
        size = (b & 0x0f).to_i64
        type = EntryType.from_code(((b >> 4) & 7).to_i32)
        shift = 4
        consumed = 1_i64
        while (b & 0x80) != 0
          b = io.read_byte || raise Git::Error.new("truncated Git object size")
          consumed += 1
          raise Git::Error.new("Git object size invalid") if shift > 56
          size |= (b & 0x7f).to_i64 << shift
          shift += 7
        end
        base_offset = nil.as(Int64?)
        base_oid = nil.as(String?)
        if type.ofs_delta?
          byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
          consumed += 1
          distance = (byte & 0x7f).to_i64
          while (byte & 0x80) != 0
            byte = io.read_byte || raise Git::Error.new("truncated Git offset delta")
            consumed += 1
            raise Git::Error.new("Git delta distance overflows") if distance >= (Int64::MAX >> 7) - 1
            distance = ((distance + 1) << 7) | (byte & 0x7f).to_i64
            raise Git::Error.new("invalid Git delta distance") if distance >= offset
          end
          raise Git::Error.new("invalid Git delta parent offset") if distance <= 0 || offset - distance < 12
          base_offset = offset - distance
        elsif type.ref_delta?
          bytes = Bytes.new(hash_size)
          io.read_fully(bytes)
          consumed += hash_size
          base_oid = bytes.hexstring
        end
        EntryHeader.new(type, size, base_offset, base_oid, offset + consumed)
      end

      # The type-and-size bytes that start an entry.
      def self.encode(type : EntryType, size : Int64) : Bytes
        header = IO::Memory.new(16)
        byte = ((type.value << 4) | (size & 0x0f)).to_u8
        rest = size >> 4
        while rest != 0
          header.write_byte(byte | 0x80)
          byte = (rest & 0x7f).to_u8
          rest >>= 7
        end
        header.write_byte(byte)
        header.to_slice
      end

      # The OFS_DELTA distance encoding from an entry back to its base.
      def self.encode_distance(distance : Int64) : Bytes
        encoded = Bytes.new(10)
        index = encoded.size - 1
        encoded[index] = (distance & 0x7f).to_u8
        while (distance >>= 7) != 0
          distance -= 1
          index -= 1
          encoded[index] = (0x80 | (distance & 0x7f)).to_u8
        end
        encoded[index, encoded.size - index]
      end
    end

    # A running SHA-1/SHA-256 over the bytes of a pack or index file.
    class Checksum
      def initialize(@format : ObjectId::Format)
        @sha1 = @format.sha1? ? Digest::SHA1.new : nil
        @sha256 = @format.sha256? ? Digest::SHA256.new : nil
      end

      def update(bytes : Bytes) : Nil
        if sha1 = @sha1
          sha1.update(bytes)
        else
          @sha256.not_nil!.update(bytes)
        end
      end

      def final : Bytes
        if sha1 = @sha1
          sha1.final
        else
          @sha256.not_nil!.final
        end
      end
    end
  end
end
