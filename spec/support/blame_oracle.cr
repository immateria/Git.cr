require "file_utils"
require "./git_oracle"

# Source-only committed-file fixtures. Git runs only as the independent oracle;
# repository contents are written by the native object writers.
module BlameOracle
  record Line, commit_oid : String, original_path : String,
    original_line : Int32, final_line : Int32, content : String,
    author : Git::Signature, committer : Git::Signature, boundary : Bool

  def self.with_repo(*, format : String = "sha1", bare : Bool = false,
                     &block : String, Git::Repository ->) : Nil
    root = File.tempname("git-blame-oracle", dir: File.realpath(Dir.tempdir))
    Dir.mkdir_p(root)
    begin
      selected = format == "sha256" ? Git::ObjectId::Format::SHA256 : Git::ObjectId::Format::SHA1
      repository = Git::Repository.init(root, bare: bare, initial_branch: "main", object_format: selected)
      yield root, repository
    ensure
      FileUtils.rm_rf(root)
    end
  end

  def self.commit(repository : Git::Repository, label : String, files : Hash(String, String),
                  parents : Array(String) = [] of String, *, time : Int64 = 1_700_000_000_i64,
                  modes : Hash(String, String) = {} of String => String) : String
    builder = Git::Index::TreeBuilder.new
    files.each do |path, content|
      builder.add(Git::Index::Entry.new(path, modes[path]? || "100644",
        repository.write_blob(content), 0, false, false))
    end
    author = Git::Signature.new("Author #{label}", "author-#{label}@example.invalid", time, 330)
    committer = Git::Signature.new("Committer #{label}", "committer-#{label}@example.invalid", time + 99, -270)
    repository.write_commit(tree: builder.write(repository), parents: parents,
      author: author, committer: committer, message: "#{label}\n")
  end

  # Byte slicing avoids Unicode iteration and newline normalization.
  # The final LF is part of each native Line#content.
  def self.split_blob(content : String) : Array(String)
    lines = [] of String
    position = 0
    while position < content.bytesize
      ending = content.byte_index('\n'.ord, position)
      size = ending ? ending - position + 1 : content.bytesize - position
      lines << content.byte_slice(position, size)
      position += size
    end
    lines
  end

  private def self.unquote_path(value : String) : String
    return value unless value.starts_with?('"')
    raise "unterminated oracle path" unless value.ends_with?('"')
    bytes = value.to_slice
    output = IO::Memory.new
    position = 1
    while position < bytes.size - 1
      byte = bytes[position]
      position += 1
      unless byte == '\\'.ord
        output.write_byte(byte)
        next
      end
      escape = bytes[position]
      position += 1
      if escape >= '0'.ord && escape <= '7'.ord
        number = escape.to_i - '0'.ord
        2.times do
          raise "invalid oracle octal path" if position >= bytes.size - 1
          digit = bytes[position].to_i - '0'.ord
          raise "invalid oracle octal path" unless 0 <= digit <= 7
          number = number * 8 + digit
          position += 1
        end
        output.write_byte(number.to_u8)
      else
        decoded = case escape
                  when 'a'.ord  then 7_u8
                  when 'b'.ord  then 8_u8
                  when 't'.ord  then 9_u8
                  when 'n'.ord  then 10_u8
                  when 'v'.ord  then 11_u8
                  when 'f'.ord  then 12_u8
                  when 'r'.ord  then 13_u8
                  when '"'.ord  then 34_u8
                  when '\\'.ord then 92_u8
                  else
                    raise "invalid oracle path escape"
                  end
        output.write_byte(decoded)
      end
    end
    output.to_s
  end

  private def self.signature(metadata : Hash(String, String), prefix : String) : Git::Signature
    mail = metadata["#{prefix}-mail"]
    raise "invalid oracle email" unless mail.starts_with?('<') && mail.ends_with?('>')
    zone = metadata["#{prefix}-tz"]
    raise "invalid oracle timezone" unless zone.bytesize == 5
    offset = zone.byte_slice(1, 2).to_i * 60 + zone.byte_slice(3, 2).to_i
    offset = -offset if zone.starts_with?('-')
    Git::Signature.new(metadata[prefix], mail.byte_slice(1, mail.bytesize - 2),
      metadata["#{prefix}-time"].to_i64, offset)
  end

  def self.parse(porcelain : String, content : String) : Array(Line)
    source = split_blob(content)
    records = split_blob(porcelain)
    result = [] of Line
    position = 0
    while position < records.size
      header = records[position].byte_slice(0, records[position].bytesize - 1).split(' ')
      raise "invalid oracle blame header" unless 3 <= header.size <= 4
      position += 1
      metadata = {} of String => String
      payload = nil.as(String?)
      while position < records.size
        record = records[position]
        position += 1
        raise "unterminated oracle blame record" unless record.ends_with?('\n')
        record = record.byte_slice(0, record.bytesize - 1)
        if record.starts_with?('\t')
          payload = record.byte_slice(1)
          break
        end
        separator = record.byte_index(' '.ord)
        key = separator ? record.byte_slice(0, separator) : record
        metadata[key] = separator ? record.byte_slice(separator + 1) : ""
      end
      raise "missing oracle blame content" unless payload
      final_line = header[2].to_i
      native_content = source[final_line - 1]
      # Porcelain appends LF even when the committed final line lacked one.
      expected_payload = native_content.ends_with?('\n') ? native_content.byte_slice(0, native_content.bytesize - 1) : native_content
      GitOracle.assert_bytes!(payload, expected_payload, "blame oracle payload #{final_line}")
      result << Line.new(header[0], unquote_path(metadata["filename"]), header[1].to_i,
        final_line, native_content, signature(metadata, "author"), signature(metadata, "committer"),
        metadata.has_key?("boundary"))
    end
    raise "oracle blame line count differs from blob" unless result.size == source.size
    result
  end

  def self.compare(root : String, repository : Git::Repository, path : String, revision : String,
                   content : String, *, first_parent : Bool = false,
                   follow_renames : Bool = true) : Git::Blame
    args = ["blame", "--line-porcelain"]
    args << "--first-parent" if first_parent
    args << "--no-follow" unless follow_renames
    args.concat([revision, "--", path])
    expected = parse(GitOracle.run_args(root, args).stdout, content)
    actual = repository.blame(path, revision, first_parent: first_parent, follow_renames: follow_renames)
    actual.path.to_slice.should eq(path.to_slice)
    actual.revision.should eq(GitOracle.run(root, "rev-parse", "#{revision}^{commit}").stdout.strip)
    actual.size.should eq(expected.size)
    actual.lines.size.should eq(expected.size)
    actual.scanned.should be >= 1
    actual.each_with_index do |line, index|
      oracle = expected[index]
      line.commit_oid.should eq(oracle.commit_oid)
      line.original_path.to_slice.should eq(oracle.original_path.to_slice)
      line.original_line.should eq(oracle.original_line)
      line.final_line.should eq(oracle.final_line)
      GitOracle.assert_bytes!(line.content, oracle.content, "blame #{revision} #{path.inspect} line #{index + 1}")
      line.author.should eq(oracle.author)
      line.committer.should eq(oracle.committer)
      line.boundary.should eq(oracle.boundary)
      line.boundary?.should eq(oracle.boundary)
    end
    actual
  end
end
