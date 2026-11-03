module Git
  # Repository identity, linked worktree metadata, and ref/HEAD resolution.
  # Does not read object payloads, indexes or current working files.
  class Metadata
    @max_search_entries : Int32
    @max_scan_bytes : Int32
    @git_dir : String
    @common : String
    MAX_DEPTH = 24

    getter root : String
    getter git_dir : String
    getter common : String
    getter object_format : ObjectId::Format

    getter bare : Bool
    getter work_tree : String?

    def initialize(root : String, *, linked_worktree_admin_dir : String? = nil,
                   git_dir : String? = nil, common_dir : String? = nil,
                   work_tree : String? = nil, follow_gitfile : Bool = true,
                   discover : Bool = false,
                   discovery_ceiling : String? = nil,
                   before_config : Proc(Location::AdmissionSite, Nil)? = nil,
                   before_implicit_bare : Proc(Nil)? = nil,
                   @max_scan_bytes : Int32 = 8_388_608, @max_search_entries : Int32 = 10_000)
      raise ArgumentError.new("invalid Git read budgets") if @max_scan_bytes < 128 || @max_search_entries < 1
      @location = Location.new(root, git_dir_option: git_dir,
        common_dir_option: common_dir, work_tree_option: work_tree,
        linked_admin: linked_worktree_admin_dir, follow_gitfile: follow_gitfile,
        discover: discover,
        discovery_ceiling: discovery_ceiling, before_config: before_config,
        before_implicit_bare: before_implicit_bare)
      @root = @location.root
      @git_dir = @location.git_dir
      @common = @location.common
      @work_tree = @location.work_tree
      @bare = @location.bare?
      @object_format = ObjectId::Format::SHA1
      @object_format_locked = false
      check!
    end

    def check! : Nil
      @location.check!
      config = File.join(@common, "config")
      selected = if File.exists?(config) || File.symlink?(config)
                   read_object_format(read_small(config, {128 * 1024, @max_scan_bytes}.min))
                 else
                   ObjectId::Format::SHA1
                 end
      if @object_format_locked && @object_format != selected
        raise Git::Error.new("Git object format changed during inspection")
      end
      @object_format = selected
      @object_format_locked = true
      objects = File.join(@common, "objects")
      raise Git::Error.new("Git object storage missing or redirected") unless Dir.exists?(objects) && !File.symlink?(objects) && File.realpath(objects) == objects
      alternates = File.join(objects, "info", "alternates")
      raise Git::Error.new("Git alternates unsupported") if File.exists?(alternates) || File.symlink?(alternates)
    end

    # Only the repository hash selection is interpreted here. Full Git
    # configuration precedence/includes remain P06; do not allow an invalid
    # extension/version combination to be read as a valid SHA-1 repository.
    private def read_object_format(raw : String) : ObjectId::Format
      section = ""
      format = ObjectId::Format::SHA1
      version = 0
      seen_format = false
      raw.each_line do |line|
        trimmed = line.strip
        next if trimmed.empty? || trimmed.starts_with?('#') || trimmed.starts_with?(';')
        if header = /\A\[([A-Za-z][A-Za-z0-9-]*)\]\z/.match(trimmed)
          section = header[1].downcase
          next
        elsif trimmed.starts_with?('[')
          section = ""
          next
        end
        parts = trimmed.split('=', 2)
        next unless parts.size == 2
        key = parts[0].strip.downcase
        value = parts[1].strip.downcase
        if section == "core" && key == "repositoryformatversion"
          parsed = value.to_i?
          raise Git::Error.new("unsupported Git repository format version") unless parsed && {0, 1}.includes?(parsed)
          version = parsed
        elsif section == "extensions" && key == "objectformat"
          selected = case value
                     when "sha1"   then ObjectId::Format::SHA1
                     when "sha256" then ObjectId::Format::SHA256
                     else               raise Git::Error.new("unsupported Git object format")
                     end
          raise Git::Error.new("conflicting Git object format declarations") if seen_format && format != selected
          format = selected
          seen_format = true
        elsif section == "extensions"
          # Worktree-local configuration is read separately by Git::Config.
          # Other required extensions still fail closed until implemented.
          if key == "worktreeconfig"
            raise Git::Error.new("invalid Git worktreeConfig extension") unless {"true", "false", "yes", "no", "on", "off", "1", "0"}.includes?(value)
          else
            raise Git::Error.new("unsupported Git repository extension: #{key}")
          end
        end
      end
      if format == ObjectId::Format::SHA256 && version != 1
        raise Git::Error.new("SHA-256 Git repository requires format version 1")
      end
      format
    end

    def head : {String?, String?}
      raw = read_pointer(File.join(@git_dir, "HEAD"))
      if raw.starts_with?("ref: ")
        ref = raw.byte_slice(5, raw.bytesize - 5)
        raise Git::Error.new("unsupported Git HEAD reference") unless safe_ref?(ref)
        {ref, resolve_ref?(ref)}
      else
        {nil, ObjectId.valid!(raw, @object_format)}
      end
    end

    def resolve_ref?(ref : String, depth : Int32 = 0) : String?
      raise Git::Error.new("Git symbolic reference cycle") if depth >= 8
      raise Git::Error.new("Git reference name rejected") unless safe_ref?(ref)
      local = ref.starts_with?("refs/worktree/") || ref.starts_with?("refs/bisect/") ||
              ref.starts_with?("refs/rewritten/")
      loose = File.join(local ? @git_dir : @common, ref)
      if File.file?(loose) || File.symlink?(loose)
        raw = read_pointer(loose)
        if raw.starts_with?("ref: ")
          return resolve_ref?(raw.byte_slice(5, raw.bytesize - 5), depth + 1)
        end
        return ObjectId.valid!(raw, @object_format)
      end
      local ? nil : read_packed_refs[ref]?
    end

    def refs(scope : String, max_entries : Int32) : {Array({String, String}), Bool}
      prefixes = case scope
                 when "heads"   then ["refs/heads"]
                 when "tags"    then ["refs/tags"]
                 when "remotes" then ["refs/remotes"]
                 when "all"     then ["refs/heads", "refs/tags", "refs/remotes"]
                 else                raise ArgumentError.new("invalid Git reference scope")
                 end
      # Scan the packed table once. There is an explicit byte bound because
      # this is metadata supplied by the repository, not an infinite stream.
      found = {} of String => String
      read_packed_refs.each do |name, oid|
        found[name] = oid if prefixes.any? { |prefix| name.starts_with?(prefix + "/") }
      end
      entries_seen = 0
      prefixes.each do |prefix|
        tree = File.join(@common, prefix)
        next unless Dir.exists?(tree)
        raise Git::Error.new("Git ref directory redirected") unless safe_metadata_dir?(tree)
        queue = [{tree, 0}]
        cursor = 0
        while cursor < queue.size
          directory, depth = queue[cursor]
          cursor += 1
          raise Git::Error.new("Git reference traversal too deep") if depth > MAX_DEPTH
          Dir.each_child(directory) do |entry|
            entries_seen += 1
            raise Git::Error.new("Git reference entry budget exceeded") if entries_seen > @max_search_entries
            path = File.join(directory, entry)
            raise Git::Error.new("Git symbolic reference entry refused") if File.symlink?(path)
            if Dir.exists?(path)
              queue << {path, depth + 1}
            elsif File.file?(path)
              name = path.byte_slice(@common.bytesize + 1, path.bytesize - @common.bytesize - 1)
              next unless safe_ref?(name)
              raw = read_pointer(path)
              # Do not follow arbitrary symbolic refs from repository data.
              found[name] = ObjectId.valid!(raw, @object_format)
            end
          end
        end
      end
      sorted = found.to_a.sort_by(&.[0])
      {sorted.first(max_entries), sorted.size > max_entries}
    end

    # Ref files and packed refs share one namespace: a packed parent/child
    # cannot coexist with a newly written loose child/parent. Exact-name
    # packed refs may be shadowed by an ordinary loose ref update.
    def require_reference_namespace!(name : String) : Nil
      read_packed_refs.each_key do |other|
        next if other == name
        if other.starts_with?(name + "/") || name.starts_with?(other + "/")
          raise Git::Error.new("Git reference file/directory namespace conflict")
        end
      end
    end

    private def safe_ref?(name : String) : Bool
      name.starts_with?("refs/") && RefName.valid?(name)
    end

    private def read_pointer(path : String, prefix : String = "") : String
      data = read_small(path, 4096)
      line = data.ends_with?('\n') ? data.byte_slice(0, data.bytesize - 1) : data
      line = line.byte_slice(0, line.bytesize - 1) if line.ends_with?('\r')
      raise Git::Error.new("invalid Git metadata pointer") unless line.valid_encoding? && !line.empty? && !line.includes?('\0') && !line.includes?('\n') && line.starts_with?(prefix)
      value = line.byte_slice(prefix.bytesize, line.bytesize - prefix.bytesize)
      raise Git::Error.new("empty Git metadata pointer") if value.empty?
      value
    end

    private def read_small(path : String, max : Int32) : String
      raise Git::Error.new("Git metadata symlink refused") if File.symlink?(path) || !File.file?(path) || File.realpath(path) != path
      data = IO::Memory.new
      File.open(path) { |f| IO.copy(f, data, max + 1) }
      raise Git::Error.new("Git metadata too large") if data.size > max
      data.to_s
    end

    private def safe_metadata_dir?(path : String) : Bool
      !File.symlink?(path) && Dir.exists?(path) && File.realpath(path) == path
    end

    private def read_packed_refs : Hash(String, String)
      path = File.join(@common, "packed-refs")
      return {} of String => String unless File.exists?(path) || File.symlink?(path)
      data = read_small(path, {8_i64 * 1024 * 1024, @max_scan_bytes.to_i64 * 8}.min.to_i)
      found = {} of String => String
      data.each_line do |line|
        next if line.empty? || line.starts_with?('#') || line.starts_with?('^')
        line = line.byte_slice(0, line.bytesize - 1) if line.ends_with?('\r')
        parts = line.split(' ', 2)
        raise Git::Error.new("invalid packed Git refs") unless parts.size == 2 && safe_ref?(parts[1])
        found[parts[1]] = ObjectId.valid!(parts[0], @object_format)
        raise Git::Error.new("packed Git refs count exceeded") if found.size > @max_search_entries
      end
      found
    end
  end
end
