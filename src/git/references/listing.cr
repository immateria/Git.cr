module Git
  struct References
    # A reference as listed by `git for-each-ref` / ls-refs: a direct ref
    # has an oid; a symbolic ref has a target and the oid it resolves to
    # (nil when the target is unborn).
    record Ref, name : String, oid : String?, symref_target : String? = nil do
      def symbolic? : Bool
        !symref_target.nil?
      end

      # The name without its refs/heads/, refs/tags/, refs/remotes/ or
      # refs/ prefix, as `git for-each-ref --format=%(refname:short)`
      # shows an unambiguous name.
      def short_name : String
        {"refs/heads/", "refs/tags/", "refs/remotes/", "refs/"}.each do |prefix|
          return name.byte_slice(prefix.bytesize) if name.starts_with?(prefix)
        end
        name
      end
    end
  end

  class Metadata
    # Every reference under prefix, loose refs shadowing packed ones,
    # sorted by name bytes. Symbolic refs are reported, not followed
    # further than their resolution.
    def list_refs(prefix : String = "refs/", max_entries : Int32 = @max_search_entries) : Array(References::Ref)
      raise ArgumentError.new("Git ref prefix must start with refs/") unless prefix.starts_with?("refs/") || prefix == "refs"
      found = {} of String => References::Ref
      read_packed_refs.each do |name, oid|
        found[name] = References::Ref.new(name, oid) if name.starts_with?(prefix)
      end
      root = File.join(@common, "refs")
      if Dir.exists?(root)
        raise Git::Error.new("Git ref directory redirected") unless safe_metadata_dir?(root)
        queue = [{root, 0}]
        cursor = 0
        seen = 0
        while cursor < queue.size
          directory, depth = queue[cursor]
          cursor += 1
          raise Git::Error.new("Git reference traversal too deep") if depth > MAX_DEPTH
          Dir.each_child(directory) do |entry|
            seen += 1
            raise Git::Error.new("Git reference entry budget exceeded") if seen > max_entries
            path = File.join(directory, entry)
            next if File.symlink?(path)
            name = path.byte_slice(@common.bytesize + 1, path.bytesize - @common.bytesize - 1)
            if Dir.exists?(path)
              # Per-worktree namespaces live in each worktree's directory.
              next if {"refs/worktree", "refs/bisect", "refs/rewritten"}.includes?(name)
              queue << {path, depth + 1} if prefix.starts_with?(name + "/") || name.starts_with?(prefix) || (name + "/").starts_with?(prefix)
            elsif File.file?(path)
              next unless name.starts_with?(prefix) && safe_ref?(name) && !name.ends_with?(".lock")
              raw = read_pointer(path)
              if raw.starts_with?("ref: ")
                target = raw.byte_slice(5, raw.bytesize - 5)
                next unless safe_ref?(target)
                oid = begin
                  resolve_ref?(target)
                rescue Git::Error
                  nil
                end
                found[name] = References::Ref.new(name, oid, target)
              else
                found[name] = References::Ref.new(name, ObjectId.valid!(raw, @object_format))
              end
            end
          end
        end
      end
      raise Git::Error.new("Git reference count exceeded") if found.size > max_entries
      found.values.sort! { |a, b| a.name.to_slice <=> b.name.to_slice }
    end

    # HEAD as a Ref: symbolic (possibly unborn) or detached.
    def head_ref : References::Ref
      ref, oid = head
      ref ? References::Ref.new("HEAD", oid, ref) : References::Ref.new("HEAD", oid)
    end

    # The target of a symbolic ref, or nil when name is a direct ref or
    # does not exist.
    def symbolic_ref?(name : String) : String?
      return head[0] if name == "HEAD"
      raise Git::Error.new("Git reference name rejected") unless safe_ref?(name)
      path = File.join(@common, name)
      return nil unless File.file?(path)
      raw = read_pointer(path)
      raw.starts_with?("ref: ") ? raw.byte_slice(5, raw.bytesize - 5) : nil
    end
  end

  class Repository
    # Every reference under prefix (`git for-each-ref`), sorted by name.
    protected def references(prefix : String = "refs/", *, max_entries : Int32 = @max_search_entries) : Array(References::Ref)
      check!
      @metadata.list_refs(prefix, max_entries)
    end

    protected def symbolic_ref?(name : String) : String?
      @metadata.symbolic_ref?(name)
    end
  end
end
