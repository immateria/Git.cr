require "./conversion/attributes"
require "set"

module Git
  # :nodoc:
  # Native built-in conversion between canonical blobs and working files.
  # External filters, ident expansion and working-tree encodings are separate.
  class Conversion
    private enum Action
      Undefined
      Binary
      Text
      TextLF
      TextCRLF
      Auto
      AutoLF
      AutoCRLF
    end

    private enum AutoCRLF
      False
      True
      Input
    end

    private struct Stats
      property nul : Int32 = 0
      property lonecr : Int32 = 0
      property lonelf : Int32 = 0
      property crlf : Int32 = 0
      property printable : Int32 = 0
      property nonprintable : Int32 = 0

      def binary? : Bool
        lonecr > 0 || nul > 0 || (printable >> 7) < nonprintable
      end
    end

    getter config : Config
    getter warnings : Array(String) = [] of String
    @warned = Set(String).new
    @attributes : Attributes
    @auto_crlf : AutoCRLF
    @default_crlf : Bool
    @safe_crlf : Bool
    @warn_crlf : Bool
    @index_oids : Hash(String, String)?
    @indexed_crlf = {} of String => Bool

    def initialize(@repository : Repository, *, config : Config? = nil,
                   attribute_tree : String? = nil,
                   attribute_blobs : Hash(String, String?)? = nil,
                   worktree_fallback : Bool = false,
                   @max_bytes : Int32 = 8_388_608,
                   @max_index_bytes : Int32 = 8_388_608,
                   @warning : Proc(String, Nil)? = nil, @check : Proc(Nil)? = nil)
      raise ArgumentError.new("invalid Git conversion byte budget") if @max_bytes < 1
      raise ArgumentError.new("invalid Git conversion index byte budget") if @max_index_bytes < 128
      @config = config || @repository.config
      @auto_crlf = if @config.value?("core.autocrlf").try(&.downcase) == "input"
                     AutoCRLF::Input
                   elsif @config.boolean?("core.autocrlf") == true
                     AutoCRLF::True
                   else
                     AutoCRLF::False
                   end
      native_crlf = {% if flag?(:win32) %} true {% else %} false {% end %}
      @default_crlf = case @auto_crlf
                      when AutoCRLF::True  then true
                      when AutoCRLF::Input then false
                      else
                        case @config.value?("core.eol").try(&.downcase)
                        when "crlf" then true
                        when "lf"   then false
                        else             native_crlf
                        end
                      end
      @warn_crlf = @config.value?("core.safecrlf").try(&.downcase) == "warn"
      @safe_crlf = !@warn_crlf && @config.boolean?("core.safecrlf") == true
      @attributes = Attributes.new(@repository, config: @config,
        attribute_tree: attribute_tree, attribute_blobs: attribute_blobs, worktree_fallback: worktree_fallback,
        max_bytes: @max_bytes, max_index_bytes: @max_index_bytes, check: @check)
    end

    # safe enables the safecrlf round-trip check for writes to the index.
    # Status and diff leave it disabled. Auto mode preserves existing CRLF
    # blobs unless the caller explicitly requests renormalization.
    def clean(path : String, data : String, *, index_oid : String? = nil,
              safe : Bool = false, renormalize : Bool = false) : String
      validate_size!(data.bytesize)
      chosen = action(path)
      return data if chosen.binary? || data.empty?
      stats = gather_stats(data)
      convert = stats.crlf > 0
      if automatic?(chosen)
        return data if stats.binary?
        convert = false if convert && !renormalize && has_indexed_crlf?(path, index_oid)
      end
      check_roundtrip!(path, stats, chosen, convert) if safe && (@safe_crlf || @warn_crlf)
      return data unless convert
      out = IO::Memory.new(data.bytesize)
      bytes = data.to_slice
      position = 0
      while position < bytes.size
        poll(position)
        byte = bytes[position]
        out.write_byte(byte) unless byte == 13 && position + 1 < bytes.size && bytes[position + 1] == 10
        position += 1
      end
      out.to_s
    end

    # Explicit text expands bare LF even in mixed or binary payloads.
    # Auto mode preserves mixed, lone-CR and binary bytes, matching Git.
    def checkout(path : String, data : String) : String
      validate_size!(data.bytesize)
      chosen = action(path)
      return data if data.empty? || !output_crlf?(chosen)
      stats = gather_stats(data)
      return data unless will_convert_to_crlf?(stats, chosen)
      validate_size!(data.bytesize.to_i64 + stats.lonelf)
      out = IO::Memory.new(data.bytesize + stats.lonelf)
      bytes = data.to_slice
      position = 0
      while position < bytes.size
        poll(position)
        byte = bytes[position]
        out.write_byte(13_u8) if byte == 10 && (position == 0 || bytes[position - 1] != 13)
        out.write_byte(byte)
        position += 1
      end
      out.to_s
    end

    private def validate_size!(size : Int) : Nil
      @check.try &.call
      raise Error.new("Git conversion byte budget exceeded") if size > @max_bytes
    end

    private def action(path : String) : Action
      values = @attributes.resolve(path)
      chosen = attribute_action(values["text"]? || Attributes::Value.new)
      chosen = attribute_action(values["crlf"]? || Attributes::Value.new) if chosen.undefined?
      unless chosen.binary?
        if (eol = values["eol"]?) && eol.kind.string?
          if eol.text == "lf"
            chosen = chosen.auto? ? Action::AutoLF : Action::TextLF
          elsif eol.text == "crlf"
            chosen = chosen.auto? ? Action::AutoCRLF : Action::TextCRLF
          end
        end
      end
      return @default_crlf ? Action::TextCRLF : Action::TextLF if chosen.text?
      if chosen.undefined?
        case @auto_crlf
        when AutoCRLF::True  then Action::AutoCRLF
        when AutoCRLF::Input then Action::AutoLF
        else                      Action::Binary
        end
      else
        chosen
      end
    end

    private def attribute_action(value : Attributes::Value) : Action
      case value.kind
      when Attributes::Kind::Set   then Action::Text
      when Attributes::Kind::Unset then Action::Binary
      when Attributes::Kind::String
        case value.text
        when "auto"  then Action::Auto
        when "input" then Action::TextLF
        else              Action::Undefined
        end
      else Action::Undefined
      end
    end

    private def automatic?(chosen : Action) : Bool
      chosen.auto? || chosen.auto_lf? || chosen.auto_crlf?
    end

    private def output_crlf?(chosen : Action) : Bool
      chosen.text_crlf? || chosen.auto_crlf? || (chosen.auto? && @default_crlf)
    end

    private def will_convert_to_crlf?(stats : Stats, chosen : Action) : Bool
      return false unless output_crlf?(chosen) && stats.lonelf > 0
      !automatic?(chosen) || (stats.lonecr == 0 && stats.crlf == 0 && !stats.binary?)
    end

    private def check_roundtrip!(path : String, stats : Stats, chosen : Action, convert : Bool) : Nil
      simulated = stats
      if convert
        simulated.lonelf += simulated.crlf
        simulated.crlf = 0
      end
      if will_convert_to_crlf?(simulated, chosen)
        simulated.crlf += simulated.lonelf
        simulated.lonelf = 0
      end
      description = if stats.crlf > 0 && simulated.crlf == 0
                      "CRLF would be replaced by LF"
                    elsif stats.lonelf > 0 && simulated.lonelf == 0
                      "LF would be replaced by CRLF"
                    end
      return unless description
      message = "#{description} in #{PathBytes.quote(path)}"
      raise Error.new(message) if @safe_crlf
      if @warn_crlf && @warned.add?(message)
        @warnings << message
        @warning.try &.call(message)
      end
    end

    private def has_indexed_crlf?(path : String, provided : String?) : Bool
      oid = provided || index_oids[path]?
      return false unless oid
      return @indexed_crlf[oid] if @indexed_crlf.has_key?(oid)
      kind, raw = @repository.object(oid, @max_bytes) { @check.try &.call }
      raise Error.new("Git conversion indexed content is not a blob") unless kind == "blob"
      stats = gather_stats(raw)
      @indexed_crlf[oid] = !stats.binary? && stats.crlf > 0
    end

    private def index_oids : Hash(String, String)
      @index_oids ||= begin
        entries = @repository.index_entries(max_bytes: @max_index_bytes, check: @check)
        result = {} of String => String
        entries.each do |entry|
          @check.try &.call
          next unless {"100644", "100755"}.includes?(entry.mode) && (entry.stage == 0 || entry.stage == 2)
          result[entry.path] = entry.oid if entry.stage == 0 || !result.has_key?(entry.path)
        end
        result
      end
    end

    private def gather_stats(data : String) : Stats
      stats = Stats.new
      bytes = data.to_slice
      position = 0
      while position < bytes.size
        poll(position)
        byte = bytes[position]
        if byte == 13
          if position + 1 < bytes.size && bytes[position + 1] == 10
            stats.crlf += 1
            position += 1
            # The skipped LF may fall exactly on a cancellation boundary.
            poll(position)
          else
            stats.lonecr += 1
          end
        elsif byte == 10
          stats.lonelf += 1
        elsif byte == 127
          stats.nonprintable += 1
        elsif byte < 32
          if byte == 8 || byte == 9 || byte == 27 || byte == 12
            stats.printable += 1
          else
            stats.nul += 1 if byte == 0
            stats.nonprintable += 1
          end
        else
          stats.printable += 1
        end
        position += 1
      end
      stats.nonprintable -= 1 if !bytes.empty? && bytes[-1] == 26
      stats
    end

    private def poll(position : Int32) : Nil
      @check.try &.call if (position & 4095) == 0
    end
  end
end
