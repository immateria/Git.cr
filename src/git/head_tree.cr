module Git
  # Typed commits and committed-tree inspection; never reads worktree files.
  # Requires only ref resolution and the object database.
  class HeadTree
    def initialize(@metadata : Metadata, @object_database : ObjectDatabase, @max_search_entries : Int32, @object_format : ObjectId::Format)
    end

    def head_entry(path : String, max_bytes : Int32, &check : -> Nil) : {String, String}
      PathBytes.validate_relative!(path)
      parts = path.split('/')
      _, oid = @metadata.head
      raise Git::Error.new("Git HEAD has no commit") unless oid
      current = Commit.read(@object_database, oid, @object_format, max_bytes) { check.call }.tree
      parts.each_with_index do |part, index|
        kind, tree_data = @object_database.object(current, max_bytes) { check.call }
        raise Git::Error.new("Git tree object expected") unless kind == "tree"
        entry = find_tree_entry(tree_data, part)
        raise Git::Error.new("path not present in Git HEAD tree") unless entry
        mode, target = entry
        if index == parts.size - 1
          return {mode, target}
        end
        raise Git::Error.new("Git path crosses a non-tree entry") unless mode == "40000"
        current = target
      end
      raise Git::Error.new("Git tree lookup failed")
    end

    def head_directory(path : String, max_bytes : Int32, &check : -> Nil) : Array({String, String, String})
      _, oid = @metadata.head
      raise Git::Error.new("Git HEAD has no commit") unless oid
      current = Commit.read(@object_database, oid, @object_format, max_bytes) { check.call }.tree
      unless path == "."
        mode, target = head_entry(path, max_bytes) { check.call }
        raise Git::Error.new("Git HEAD entry is not a directory") unless mode == "40000"
        current = target
      end
      kind, raw = @object_database.object(current, max_bytes) { check.call }
      raise Git::Error.new("Git tree object expected") unless kind == "tree"
      parse_tree(raw)
    end

    def read_head_file(path : String, max_bytes : Int32, &check : -> Nil) : {String, String}
      mode, oid = head_entry(path, max_bytes) { check.call }
      raise Git::Error.new("Git HEAD entry is not a regular file") unless {"100644", "100755"}.includes?(mode)
      kind, content = @object_database.object(oid, max_bytes) { check.call }
      raise Git::Error.new("Git HEAD entry is not a blob") unless kind == "blob"
      raise Git::Error.new("Git HEAD blob is not UTF-8 text") unless content.valid_encoding? && !content.includes?('\0')
      {oid, content}
    end

    private def find_tree_entry(raw : String, name : String) : {String, String}?
      parse_tree(raw).each do |entry_name, mode, oid|
        return {mode, oid} if entry_name == name
      end
      nil
    end

    def parse_tree(raw : String) : Array({String, String, String})
      results = [] of {String, String, String}
      pos = 0
      while pos < raw.bytesize
        space = pos
        while space < raw.bytesize && raw.byte_at(space) != 32
          space += 1
        end
        raise Git::Error.new("Git tree mode truncated") if space >= raw.bytesize
        nul = space + 1
        while nul < raw.bytesize && raw.byte_at(nul) != 0
          nul += 1
        end
        raise Git::Error.new("Git tree name truncated") if nul >= raw.bytesize
        raise Git::Error.new("Git tree OID truncated") if nul + 1 + @object_format.bytesize > raw.bytesize
        mode = raw.byte_slice(pos, space - pos)
        mode = "40000" if mode == "040000"
        raise Git::Error.new("unsupported Git tree mode") unless {"40000", "100644", "100755", "120000", "160000"}.includes?(mode)
        name = raw.byte_slice(space + 1, nul - space - 1)
        PathBytes.validate_tree_name!(name)
        oid = raw.byte_slice(nul + 1, @object_format.bytesize).to_slice.hexstring
        results << {name, mode, oid}
        raise Git::Error.new("Git tree entry budget exceeded") if results.size > @max_search_entries
        pos = nul + 1 + @object_format.bytesize
      end
      results
    end
  end
end
