module Git
  struct References
    class Transaction
      # The packed-refs file contains comments, direct refs, and optionally
      # peeled OIDs following an annotated tag. Preserve the exact bytes of
      # unrelated entries. Refuse unknown/malformed data rather than dropping
      # metadata or treating peeled lines as independent refs.
      private def self.remove_packed_ref(raw : String?, name : String,
                                         format : ObjectId::Format) : {String, Bool}
        return {"", false} unless raw
        output = IO::Memory.new
        dropping = false
        found = false
        previous_ref = false
        raw.each_line(chomp: false) do |line|
          payload = line.ends_with?('\n') ? line.byte_slice(0, line.bytesize - 1) : line
          payload = payload.byte_slice(0, payload.bytesize - 1) if payload.ends_with?('\r')
          if payload.starts_with?('#')
            output.write(line.to_slice)
            dropping = false
            previous_ref = false
          elsif payload.starts_with?('^')
            raise Error.new("invalid packed Git peeled ref") unless previous_ref
            ObjectId.valid!(payload.byte_slice(1, payload.bytesize - 1), format)
            output.write(line.to_slice) unless dropping
            previous_ref = false
          else
            fields = payload.split(' ', 2)
            raise Error.new("invalid packed Git ref entry") unless fields.size == 2 && fields[1].starts_with?("refs/")
            ObjectId.valid!(fields[0], format)
            RefName.valid!(fields[1])
            dropping = fields[1] == name
            raise Error.new("duplicate packed Git ref") if dropping && found
            found ||= dropping
            previous_ref = true
            output.write(line.to_slice) unless dropping
          end
        end
        {output.to_s, found}
      end

      private def self.read_packed_file?(path : String, max_bytes : Int32) : String?
        info = File.info?(path, follow_symlinks: false)
        return nil unless info
        raise Error.new("Git packed refs redirected") unless info.type.file? && !File.symlink?(path)
        raise Error.new("Git packed ref byte budget exceeded") if info.size > max_bytes
        io = IO::Memory.new
        File.open(path) { |f| IO.copy(f, io, max_bytes.to_i64 + 1) }
        raise Error.new("Git packed ref byte budget exceeded") if io.size > max_bytes
        io.to_s
      end

      private def self.validate_optional_log!(path : String) : Nil
        info = File.info?(path, follow_symlinks: false)
        return unless info
        raise Error.new("Git reflog redirected") unless info.type.file? && !File.symlink?(path)
        directory = File.dirname(path)
        while Dir.exists?(directory)
          raise Error.new("Git reflog directory redirected") if File.symlink?(directory) || File.realpath(directory) != directory
          break if directory == File.dirname(directory)
          directory = File.dirname(directory)
        end
      end

      # Prepare and publish multiple direct-reference updates. Acquire every
      # used for its transaction lock and eventual rename.
      private def self.read_packed_from_directory?(dir : DescriptorPath::Directory,
                                                   max_bytes : Int32) : String?
        io = dir.open_file?("packed-refs")
        return nil unless io
        begin
          raise Error.new("Git packed refs redirected") unless io.info.type.file?
          data = IO::Memory.new
          IO.copy(io, data, max_bytes.to_i64 + 1)
          raise Error.new("Git packed refs budget exceeded") if data.size > max_bytes
          data.to_s
        ensure
          io.close
        end
      end

      # One bounded pass validates and removes all packed deletion entries,
      # including annotated-tag peel records, retaining untouched byte spans.
      private def self.remove_packed_refs(raw : String?, names : Set(String),
                                          format : ObjectId::Format) : {String, Set(String)}
        found = Set(String).new
        return {"", found} unless raw
        output = IO::Memory.new
        dropping = false
        previous_ref = false
        raw.each_line(chomp: false) do |line|
          payload = line.ends_with?('\n') ? line.byte_slice(0, line.bytesize - 1) : line
          payload = payload.byte_slice(0, payload.bytesize - 1) if payload.ends_with?('\r')
          if payload.starts_with?('#')
            output.write(line.to_slice)
            dropping = false
            previous_ref = false
          elsif payload.starts_with?('^')
            raise Error.new("invalid packed Git peeled ref") unless previous_ref
            ObjectId.valid!(payload.byte_slice(1, payload.bytesize - 1), format)
            output.write(line.to_slice) unless dropping
            previous_ref = false
          else
            fields = payload.split(' ', 2)
            raise Error.new("invalid packed Git ref entry") unless fields.size == 2 && fields[1].starts_with?("refs/")
            ObjectId.valid!(fields[0], format)
            RefName.valid!(fields[1])
            dropping = names.includes?(fields[1])
            if dropping
              raise Error.new("duplicate packed Git ref") if found.includes?(fields[1])
              found.add(fields[1])
            end
            previous_ref = true
            output.write(line.to_slice) unless dropping
          end
        end
        {output.to_s, found}
      end
    end
  end
end
