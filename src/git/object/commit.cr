module Git
  record Commit, oid : String, tree : String, parents : Array(String), author : String,
    committer : String, subject : String do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field("oid", oid)
        json.field("tree", tree)
        json.field("parents", parents)
        json.field("author", author)
        json.field("committer", committer)
        json.field("subject", subject)
      end
    end

    def self.read(objects : ObjectDatabase, oid : String, format : ObjectId::Format,
                  max_bytes : Int32, &check : -> Nil) : Commit
      kind, raw = objects.object(ObjectId.valid!(oid, format), max_bytes) { check.call }
      raise Git::Error.new("Git object is not a commit") unless kind == "commit"
      raise Git::Error.new("invalid Git commit text") unless raw.valid_encoding?
      separator = raw.index("\n\n") || raise Git::Error.new("Git commit missing header separator")
      header = raw.byte_slice(0, separator)
      message = raw.byte_slice(separator + 2, raw.bytesize - separator - 2)
      tree = nil.as(String?)
      parents = [] of String
      author = ""
      committer = ""
      header.each_line do |line|
        case
        when line.starts_with?("tree ") then tree = ObjectId.valid!(line.byte_slice(5).strip, format)
        when line.starts_with?("parent ")
          raise Git::Error.new("Git commit has too many parents") if parents.size >= 16
          parents << ObjectId.valid!(line.byte_slice(7).strip, format)
        when line.starts_with?("author ")    then author = line.byte_slice(7).strip
        when line.starts_with?("committer ") then committer = line.byte_slice(10).strip
        end
      end
      raise Git::Error.new("invalid Git commit header") if tree.nil? || author.empty? || committer.empty?
      subject = message.lines.first? || ""
      # Keep the output predictable and bounded regardless of message size.
      Commit.new(oid, tree.not_nil!, parents, author.byte_slice(0, {author.bytesize, 512}.min),
        committer.byte_slice(0, {committer.bytesize, 512}.min), subject.byte_slice(0, {subject.bytesize, 1024}.min))
    end
  end
end

module Git
  struct Commit
    # An extra commit header, including optional Git signature/mergetag text.
    # Interior LF bytes are written as Git continuation lines (leading space).
    record Header, name : String, value : String do
      def encode : String
        unless /\A[a-z][a-z0-9-]*\z/.matches?(name) &&
               !{"tree", "parent", "author", "committer"}.includes?(name)
          raise Error.new("invalid or reserved Git commit header")
        end
        raise Error.new("invalid Git commit header value") if value.each_byte.any? { |b| b == 0 || b == 13 }
        "#{name} #{value.gsub("\n", "\n ")}\n"
      end
    end

    # Low-level canonical commit body, independently of refs, the index,
    # configured identities or Git subprocesses. No referent existence is
    # inferred: callers can separately require the tree/parents to exist.
    def self.encode(*, tree : String, parents : Enumerable(String),
                    author : Signature, committer : Signature,
                    message : String, format : ObjectId::Format = ObjectId::Format::SHA1,
                    extra_headers : Enumerable(Header) = [] of Header,
                    max_bytes : Int64 = Int64::MAX,
                    max_parents : Int32 = Int32::MAX,
                    max_headers : Int32 = Int32::MAX) : String
      raise ArgumentError.new("invalid Git commit budgets") if max_bytes < 0 || max_parents < 0 || max_headers < 0
      ObjectId.valid!(tree, format)
      lines = ["tree #{tree}\n"]
      parent_count = 0
      parents.each do |parent|
        raise Error.new("Git commit parent budget exceeded") if parent_count >= max_parents
        lines << "parent #{ObjectId.valid!(parent, format)}\n"
        parent_count += 1
      end
      lines << "author #{author.to_git_header}\n"
      lines << "committer #{committer.to_git_header}\n"
      header_count = 0
      extra_headers.each do |header|
        raise Error.new("Git commit header budget exceeded") if header_count >= max_headers
        lines << header.encode
        header_count += 1
      end
      total = message.bytesize.to_i64 + 1
      lines.each do |line|
        total += line.bytesize
        raise Error.new("Git commit byte budget exceeded") if total > max_bytes || total > Int32::MAX - 128
      end
      raise Error.new("Git commit byte budget exceeded") if total > max_bytes
      String.build do |io|
        lines.each { |line| io << line }
        io << '\n' << message
      end
    end
  end
end
