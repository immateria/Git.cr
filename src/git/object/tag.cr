module Git
  # Encoding for annotated tag objects. Tag references and reference
  # transactions are a separate Git layer, not a host permission.
  module Tag
    def self.encode(*, object : String, type : String, name : String,
                    message : String, tagger : Signature? = nil,
                    format : ObjectId::Format = ObjectId::Format::SHA1,
                    max_bytes : Int64 = Int64::MAX) : String
      raise ArgumentError.new("invalid Git tag byte budget") if max_bytes < 0
      ObjectId.valid!(object, format)
      raise Error.new("invalid Git tag target type") unless {"blob", "tree", "commit", "tag"}.includes?(type)
      raise Error.new("invalid Git tag name") unless RefName.valid?("refs/tags/#{name}")
      lines = ["object #{object}\n", "type #{type}\n", "tag #{name}\n"]
      if tagger
        lines << "tagger #{tagger.to_git_header}\n"
      end
      total = message.bytesize.to_i64 + 1
      lines.each do |line|
        total += line.bytesize
        raise Error.new("Git tag byte budget exceeded") if total > max_bytes || total > Int32::MAX - 128
      end
      raise Error.new("Git tag byte budget exceeded") if total > max_bytes
      String.build do |io|
        lines.each { |line| io << line }
        io << '\n' << message
      end
    end
  end
end
