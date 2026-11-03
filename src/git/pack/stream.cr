require "lib_z"
require "digest/sha1"
require "digest/sha256"
require "digest/crc32"

module Git
  # Native pack-file support: reading a pack stream entry by entry,
  # writing packs and their .idx/.rev companions, and indexing received
  # packs (Git's index-pack).
  module Pack
    SIGNATURE = "PACK".to_slice

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

    # Buffered sequential reader over a pack stream. Every consumed byte is
    # hashed into the pack checksum (until the trailer), folded into the
    # current entry's CRC32 and optionally copied to a tee, so a pack can be
    # parsed while it is received without knowing its length in advance.
    class StreamReader
      getter position : Int64 = 0_i64
      getter crc : UInt32 = 0_u32

      @buffer : Bytes
      @start = 0
      @finish = 0
      @hashing = true

      def initialize(@io : IO, @format : ObjectId::Format, @tee : IO? = nil,
                     buffer_size : Int32 = 65_536)
        @buffer = Bytes.new(buffer_size)
        @checksum = Checksum.new(@format)
      end

      def begin_entry : Nil
        @crc = Digest::CRC32.initial
      end

      def read_byte : UInt8?
        return nil unless fill
        byte = @buffer[@start]
        consume(1)
        byte
      end

      def read_exact(size : Int32) : Bytes
        output = Bytes.new(size)
        copied = 0
        while copied < size
          raise Git::Error.new("Git pack stream truncated") unless fill
          part = Math.min(size - copied, @finish - @start)
          output[copied, part].copy_from(@buffer[@start, part])
          consume(part)
          copied += part
        end
        output
      end

      # Read the trailing checksum: it is not part of the hashed body.
      def read_trailer : Bytes
        @hashing = false
        read_exact(@format.bytesize)
      end

      def body_checksum : Bytes
        @checksum.final
      end

      # Whether the stream has ended, consuming nothing.
      def eof? : Bool
        !fill
      end

      # Inflate one zlib stream whose inflated length must equal size.
      # Exactly the compressed bytes are consumed.
      def inflate(size : Int64, max_bytes : Int64) : Bytes
        raise Git::Error.new("Git pack object exceeds byte budget") if size > max_bytes || size > Int32::MAX - 1
        output = Bytes.new(size.to_i + 1)
        written = Inflate.run(output) do |stream|
          raise Git::Error.new("Git pack stream truncated") unless fill
          stream.value.next_in = @buffer.to_unsafe + @start
          stream.value.avail_in = (@finish - @start).to_u32
          status = LibZ.inflate(stream, LibZ::Flush::NO_FLUSH)
          consume((@finish - @start) - stream.value.avail_in.to_i)
          status
        end
        raise Git::Error.new("Git packed entry size mismatch") unless written == size
        output[0, size.to_i]
      end

      private def fill : Bool
        return true if @start < @finish
        @start = 0
        @finish = @io.read(@buffer)
        @finish > 0
      end

      private def consume(count : Int32) : Nil
        return if count == 0
        chunk = @buffer[@start, count]
        @checksum.update(chunk) if @hashing
        @crc = Digest::CRC32.update(chunk, @crc)
        @tee.try &.write(chunk)
        @start += count
        @position += count
      end
    end

    # A direct zlib inflate loop that reports how much output was produced.
    # The caller's block supplies input and runs one inflate step.
    module Inflate
      def self.run(output : Bytes, & : LibZ::ZStream* -> LibZ::Error) : Int64
        stream = LibZ::ZStream.new
        stream.zalloc = LibZ::AllocFunc.new { |_opaque, items, size| GC.malloc(items * size) }
        stream.zfree = LibZ::FreeFunc.new { |_opaque, address| GC.free(address) }
        status = LibZ.inflateInit2(pointerof(stream), LibZ::MAX_BITS, LibZ.zlibVersion, sizeof(LibZ::ZStream))
        raise Git::Error.new("Git zlib initialization failed") unless status.ok?
        begin
          stream.next_out = output.to_unsafe
          stream.avail_out = output.size.to_u32
          loop do
            status = yield pointerof(stream)
            case status
            when .stream_end?
              break
            when .ok?
              raise Git::Error.new("Git packed entry size mismatch") if stream.avail_out == 0
            when .buf_error?
              raise Git::Error.new("Git packed entry size mismatch") if stream.avail_out == 0
            else
              raise Git::Error.new("Git packed entry is not valid zlib data (#{status})")
            end
          end
          stream.total_out.to_i64
        ensure
          LibZ.inflateEnd(pointerof(stream))
        end
      end
    end
  end
end
