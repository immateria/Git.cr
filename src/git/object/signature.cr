module Git
  # Native Git identity/date header value shared by commits and annotated tags.
  # No ambient author/committer environment, timezone or clock is consulted.
  record Signature, name : String, email : String, unix_seconds : Int64,
    offset_minutes : Int32 do
    # Parse the canonical identity/date form stored in Git commit and reflog
    # headers. This does not consult local configuration, environment or wall
    # clock; callers receive exactly the identity/time encoded by the object.
    #
    # "Name <email> seconds +hhmm", read as bytes: a name need not be UTF-8
    # (older commits often carry Latin-1).
    def self.parse_git_header(value : String) : Signature
      bytes = value.to_slice
      close = bytes.rindex('>'.ord.to_u8) || raise Error.new("invalid Git identity header")
      open = bytes[0, close].rindex('<'.ord.to_u8) || raise Error.new("invalid Git identity header")
      raise Error.new("invalid Git identity header") unless open >= 2 && bytes[open - 1] == ' '.ord.to_u8
      name = value.byte_slice(0, open - 1)
      email = value.byte_slice(open + 1, close - open - 1)
      match = /\A (-?\d+) ([+-])(\d{2})(\d{2})\z/.match(value.byte_slice(close + 1).scrub) ||
              raise Error.new("invalid Git identity header")
      seconds = match[1].to_i64? || raise Error.new("invalid Git identity timestamp")
      hours = match[3].to_i? || raise Error.new("invalid Git identity offset")
      minutes = match[4].to_i? || raise Error.new("invalid Git identity offset")
      raise Error.new("invalid Git identity offset") if hours > 23 || minutes > 59
      offset = hours * 60 + minutes
      offset = -offset if match[2] == "-"
      signature = Signature.new(name, email, seconds, offset)
      # Reuse the writer validation so parsed values cannot bypass the public
      # identity contract.
      signature.to_git_header
      signature
    end

    def to_git_header : String
      raise Error.new("Git identity name is empty") if name.empty?
      raise Error.new("Git identity email is empty") if email.empty?
      {name, email}.each do |part|
        if part.each_byte.any? { |byte| byte == 0 || byte == 10 || byte == 13 || byte == 60 || byte == 62 }
          raise Error.new("invalid Git identity header")
        end
      end
      minutes = offset_minutes.to_i64.abs
      raise Error.new("invalid Git identity time offset") if minutes > 23 * 60 + 59
      hours = minutes // 60
      remainder = minutes % 60
      zone = sprintf("%s%02d%02d", offset_minutes < 0 ? "-" : "+", hours, remainder)
      "#{name} <#{email}> #{unix_seconds} #{zone}"
    end
  end
end
