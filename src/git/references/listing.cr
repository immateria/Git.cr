module Git
  module References
    # A reference as listed by `git for-each-ref` / ls-refs: a direct ref
    # has an oid; a symbolic ref has a target and the oid it resolves to
    # (nil when the target is unborn).
    record Ref, name : String, oid : String?, symref_target : String? = nil do
      def symbolic? : Bool
        !symref_target.nil?
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
    def references(prefix : String = "refs/", *, max_entries : Int32 = @max_search_entries) : Array(References::Ref)
      check!
      @metadata.list_refs(prefix, max_entries)
    end

    # HEAD as a symbolic (possibly unborn) or detached ref.
    def head_reference : References::Ref
      @metadata.head_ref
    end

    def symbolic_ref?(name : String) : String?
      @metadata.symbolic_ref?(name)
    end
  end
end

module Git
  class Repository
    # Point a symbolic ref (HEAD or refs/...) at target, as
    # `git symbolic-ref` does. The ref is written through an exclusive
    # .lock and renamed into place; target need not exist yet. With
    # expected_target, the current value must match (nil: must not exist).
    def set_symbolic_ref(name : String, target : String, *, expected_target : String? | Symbol = :any,
                         check : Proc(Nil)? = nil) : Nil
      check!
      raise Error.new("invalid Git symbolic ref target") unless target.starts_with?("refs/") && RefName.valid?(target)
      path = symbolic_ref_path(name)
      unless expected_target == :any
        current = File.exists?(path) ? symbolic_ref?(name) : nil
        raise Error.new("Git symbolic ref #{name} changed (expected #{expected_target.inspect}, found #{current.inspect})") unless current == expected_target
      end
      Dir.mkdir_p(File.dirname(path))
      lock = path + ".lock"
      check.try &.call
      fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o644)
      raise Error.new("Git ref lock #{name}.lock exists or cannot be created") if fd < 0
      begin
        io = IO::FileDescriptor.new(fd)
        begin
          io.write("ref: #{target}\n".to_slice)
          io.flush
          io.fsync
        ensure
          io.close
        end
        File.rename(lock, path)
        lock = nil
        File.open(File.dirname(path)) { |dir| dir.fsync }
      ensure
        lock.try { |stale| File.delete?(stale) }
      end
    end

    # Remove a symbolic ref (not HEAD) such as refs/remotes/origin/HEAD.
    def delete_symbolic_ref(name : String) : Nil
      check!
      raise Error.new("Git HEAD cannot be deleted") if name == "HEAD"
      path = symbolic_ref_path(name)
      raise Error.new("Git ref #{name} is not symbolic") unless symbolic_ref?(name)
      File.delete(path)
    end

    private def symbolic_ref_path(name : String) : String
      if name == "HEAD"
        File.join(@git_dir, "HEAD")
      else
        raise Error.new("invalid Git symbolic ref name") unless name.starts_with?("refs/") && RefName.valid?(name)
        File.join(@common, name)
      end
    end
  end
end
