module Git
  # Standalone Git config reader. Sources and environment-derived context are
  # supplied by the caller, never inherited from this process. The parser is
  # independent from the host tool authorization policy.
  class Config
    enum Scope
      System
      Global
      Local
      Worktree
      Command
    end

    record Source, scope : Scope, path : String
    record Entry, name : String, value : String?, scope : Scope, origin : String
    record Context, git_dir : String? = nil, work_tree : String? = nil,
      branch : String? = nil, home : String? = nil

    getter entries : Array(Entry)

    def self.load(sources : Array(Source), *, context : Context? = nil,
                  max_bytes : Int32 = 8_388_608,
                  max_entries : Int32 = 100_000,
                  max_include_depth : Int32 = 10,
                  commands : Array({String, String?}) = [] of {String, String?}) : Config
      raise ArgumentError.new("invalid Git config budgets") if max_bytes < 128 || max_entries < 1 || max_include_depth < 1
      result = Loader.new(context, max_bytes, max_entries, max_include_depth)
      sources.each { |source| result.read(source.path, source.scope, 0) }
      commands.each { |name, value| result.add_command(name, value) }
      # Git permits an includeIf hasconfig condition to depend on a remote URL
      # declared later (even in a subsequent scope or a command override).
      # In the first pass, ordinary includes are followed but hasconfig
      # includes are deferred. Replaying with these URLs avoids allowing a
      # conditionally included file to make its own condition true.
      if result.hasconfig_seen?
        urls = result.entries.compact_map do |entry|
          entry.value if result.remote_url?(entry.name)
        end
        result = Loader.new(context, max_bytes, max_entries, max_include_depth, urls)
        sources.each { |source| result.read(source.path, source.scope, 0) }
        commands.each { |name, value| result.add_command(name, value) }
      end
      new(result.entries)
    end

    protected def initialize(@entries : Array(Entry))
    end

    def values(name : String) : Array(String?)
      query = Key.normalize(name)
      @entries.select { |item| item.name == query }.map(&.value)
    end

    # The last entry is effective for scalar Git config lookups. Returning
    # the entry (rather than only its String?) distinguishes an absent key
    # from a present implicit/no-value key and preserves scope/provenance.
    def effective_entry?(name : String) : Entry?
      query = Key.normalize(name)
      @entries.reverse_each do |item|
        return item if item.name == query
      end
      nil
    end

    def value?(name : String) : String?
      effective_entry?(name).try(&.value)
    end

    # Git --type=bool: a key with no equals sign means true; an explicitly
    # empty value means false. Integer-looking values are limited to signed
    # 32-bit Git boolean conversion, not unrestricted nonzero text.
    def boolean?(name : String) : Bool?
      return nil unless entry = effective_entry?(name)
      Value.boolean(entry.value, entry.name)
    end

    # Git --type=int: checked signed 64-bit conversion with Git's base
    # prefixes and binary-size suffixes. Malformed or overflowing values are
    # errors, never defaults. Missing keys return nil.
    def integer?(name : String) : Int64?
      return nil unless entry = effective_entry?(name)
      Value.integer(entry.value, entry.name, Int64::MAX.to_i128)
    end

    # Git --type=bool-or-int preserves explicit textual booleans, but numeric
    # forms (including "0" and "1") are returned as signed 32-bit integers.
    def boolean_or_integer?(name : String) : Bool | Int32 | Nil
      return nil unless entry = effective_entry?(name)
      return true unless value = entry.value
      return false if value.empty?
      return true if {"true", "yes", "on"}.includes?(value.downcase)
      return false if {"false", "no", "off"}.includes?(value.downcase)
      Value.integer(value, entry.name, Int32::MAX.to_i128).to_i32
    end

    # These are the only scopes Git recognizes as protected configuration.
    # Whether a caller-provided file is actually trusted remains host policy.
    def protected_entries(name : String) : Array(Entry)
      query = Key.normalize(name)
      @entries.select do |entry|
        entry.name == query && {Scope::System, Scope::Global, Scope::Command}.includes?(entry.scope)
      end
    end
  end
end
