require "set"

module Git
  # Byte-exact Git tree encoding. This is a reusable object-storage primitive,
  # not a working-tree operation or an index/ref transaction.
  module Tree
    record Entry, name : String, mode : String, oid : String

    # Encode entries in Git tree order. A directory sorts as if its name ends
    # with '/', while all other entries sort as if terminated by NUL. Invalid
    # UTF-8 bytes remain unmodified. This low-level writer validates structure
    # and OID width but deliberately does not require referenced objects to
    # exist (the equivalent of `git mktree --missing`).
    def self.encode(entries : Enumerable(Entry), format : ObjectId::Format, *,
                    max_bytes : Int64 = Int64::MAX,
                    max_entries : Int32 = Int32::MAX) : String
      raise ArgumentError.new("invalid Git tree byte budget") if max_bytes < 0
      raise ArgumentError.new("invalid Git tree entry budget") if max_entries < 0
      seen = Set(String).new
      prepared = [] of {Entry, String}
      size = 0_i64
      entries.each do |entry|
        raise Error.new("Git tree entry budget exceeded") if prepared.size >= max_entries
        PathBytes.validate_tree_name!(entry.name)
        raise Error.new("duplicate Git tree entry name") unless seen.add?(entry.name)
        mode = canonical_mode(entry.mode)
        ObjectId.valid!(entry.oid, format)
        size += mode.bytesize.to_i64 + entry.name.bytesize + 2 + format.bytesize
        raise Error.new("Git tree byte budget exceeded") if size > max_bytes || size > Int32::MAX - 128
        prepared << {entry, mode}
      end
      prepared.sort! do |a, b|
        compare_names(a[0].name, a[1], b[0].name, b[1])
      end
      String.build do |io|
        prepared.each do |entry, mode|
          io << mode << ' ' << entry.name << '\0'
          io.write(entry.oid.hexbytes)
        end
      end
    end

    private def self.canonical_mode(mode : String) : String
      case mode
      when "040000", "40000"                      then "40000"
      when "100644", "100755", "120000", "160000" then mode
      else
        raise Error.new("unsupported Git tree entry mode")
      end
    end

    # Git base_name_compare: names are unsigned byte strings; a directory
    # has a virtual slash at its end rather than the file's virtual NUL.
    private def self.compare_names(aname : String, amode : String,
                                   bname : String, bmode : String) : Int32
      min = {aname.bytesize, bname.bytesize}.min
      i = 0
      while i < min
        diff = aname.byte_at(i).to_i - bname.byte_at(i).to_i
        return diff unless diff == 0
        i += 1
      end
      achar = aname.bytesize == min ? (amode == "40000" ? 47 : 0) : aname.byte_at(min).to_i
      bchar = bname.bytesize == min ? (bmode == "40000" ? 47 : 0) : bname.byte_at(min).to_i
      achar - bchar
    end
  end
end
