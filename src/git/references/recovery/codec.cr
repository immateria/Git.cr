module Git
  struct References
    struct Recovery
      private def self.encode(metadata : Metadata, format : ObjectId::Format,
                              changes : Array(Change), logs : Array(LogIntent),
                              index_image : Index::Image? = nil) : String
        validate_logs!(changes, logs, format)
        body = String.build do |io|
          io << (index_image ? MAGIC_V3 : MAGIC) << '\n'
          io << (format == ObjectId::Format::SHA1 ? "sha1" : "sha256") << '\n'
          io << metadata.git_dir.to_slice.hexstring << '\n'
          io << changes.size << '\n'
          changes.sort_by(&.name).each do |change|
            io << (change.is_a?(Update) ? 'U' : 'D') << '\t'
            io << change.name.to_slice.hexstring << '\t'
            io << (change.expected_oid || "-") << '\t'
            io << (change.is_a?(Update) ? change.new_oid : "-") << '\n'
          end
          io << logs.size << '\n'
          logs.each do |log|
            io << "L\t" << (log.private_base ? 'W' : 'C') << '\t'
            io << log.relative.to_slice.hexstring << '\t' << log.line.to_slice.hexstring << '\t'
            io << log.before_size << '\t' << log.before_sha256 << '\t'
            io << (log.attached_ref.try(&.to_slice.hexstring) || "-") << '\n'
          end
          if image = index_image
            io << "I\t" << (image.before_sha256 || "-") << '\t'
            io << image.data.to_slice.hexstring << '\n'
          end
        end
        "#{Digest::SHA256.hexdigest(body)}\n#{body}"
      end

      # Version 1 remains readable for already persisted reflog-free journals.
      # New records carry baselines and complete reflog lines for idempotent
      # replay after a killed writer, including a partially appended line.
      private def self.decode(raw : String, metadata : Metadata,
                              format : ObjectId::Format) : Stored
        parts = raw.split('\n')
        raise Error.new("invalid Git recovery journal envelope") if parts.size < 6 || !raw.ends_with?('\n')
        checksum = parts.shift
        body = raw.byte_slice(checksum.bytesize + 1, raw.bytesize - checksum.bytesize - 1)
        raise Error.new("Git recovery journal checksum mismatch") unless checksum == Digest::SHA256.hexdigest(body)
        version = parts.shift
        raise Error.new("unsupported Git recovery journal version") unless {MAGIC, MAGIC_V1, MAGIC_V3}.includes?(version)
        raise Error.new("Git recovery journal exceeds legacy byte budget") if version != MAGIC_V3 && raw.bytesize > MAX_BYTES
        raise Error.new("Git recovery journal object format mismatch") unless parts.shift == (format == ObjectId::Format::SHA1 ? "sha1" : "sha256")
        gitdir = decode_hex!(parts.shift)
        raise Error.new("Git recovery journal belongs to another worktree") unless gitdir == metadata.git_dir
        count = parts.shift.to_i?
        raise Error.new("invalid Git recovery entry count") unless count && count > 0 && count <= MAX_CHANGES
        raise Error.new("invalid Git recovery journal length") if parts.size < count + 1
        changes = [] of Change
        parts.shift(count).each do |line|
          fields = line.split('\t')
          raise Error.new("invalid Git recovery entry") unless fields.size == 4
          kind, name_hex, old, new_value = fields
          name = decode_hex!(name_hex)
          expected = old == "-" ? nil : ObjectId.valid!(old, format)
          case kind
          when "U"
            changes << Update.new(name, ObjectId.valid!(new_value, format), expected)
          when "D"
            raise Error.new("invalid Git recovery deletion") unless expected && new_value == "-"
            changes << Delete.new(name, expected)
          else
            raise Error.new("unsupported Git recovery operation")
          end
        end
        validate!(changes, format)
        logs = [] of LogIntent
        if version == MAGIC || version == MAGIC_V3
          log_count = parts.shift?.try(&.to_i?)
          raise Error.new("invalid Git recovery reflog count") unless log_count && log_count >= 0 && log_count <= MAX_CHANGES * 2
          expected_lines = log_count + (version == MAGIC_V3 ? 2 : 1)
          raise Error.new("invalid Git recovery journal length") unless parts.size == expected_lines && parts.last.empty?
          parts.shift(log_count).each do |line|
            fields = line.split('\t')
            raise Error.new("invalid Git recovery reflog entry") unless fields.size == 7 && fields[0] == "L" && {"W", "C"}.includes?(fields[1])
            relative = decode_hex!(fields[2])
            entry = decode_hex!(fields[3])
            size = fields[4].to_i?
            raise Error.new("invalid Git recovery reflog baseline") unless size && size >= 0 && size <= MAX_REFLOG_BYTES
            attached = fields[6] == "-" ? nil : decode_hex!(fields[6])
            logs << LogIntent.new(fields[1] == "W", relative, entry, size, fields[5], attached)
          end
        else
          raise Error.new("invalid Git recovery journal length") unless parts.size == 1 && parts.last.empty?
        end
        index_image = nil.as(Index::Image?)
        if version == MAGIC_V3
          fields = parts.shift?.try(&.split('\t'))
          raise Error.new("invalid Git recovery index record") unless fields && fields.size == 3 && fields[0] == "I"
          before = fields[1] == "-" ? nil : fields[1]
          if before
            raise Error.new("invalid Git recovery predecessor checksum") unless /\A[0-9a-f]{64}\z/.matches?(before)
          end
          hex = fields[2]
          raise Error.new("invalid Git recovery index payload") unless hex.bytesize.even? &&
                                                                       hex.bytesize <= MAX_INDEX_IMAGE_BYTES * 2 &&
                                                                       hex.each_byte.all? { |byte| (48 <= byte <= 57) || (97 <= byte <= 102) }
          index_image = Index::Image.new(before, String.new(hex.hexbytes))
        end
        validate_logs!(changes, logs, format)
        Stored.new(changes, logs, index_image)
      end

      private def self.decode_hex!(hex : String) : String
        raise Error.new("invalid Git recovery raw name") unless hex.bytesize.even? && hex.bytesize <= 8192 &&
                                                                hex.each_byte.all? { |b| (48 <= b <= 57) || (97 <= b <= 102) }
        String.new(hex.hexbytes)
      end
    end
  end
end
