require "set"

module Git
  class Repository
    # Write a commit's tree into an empty worktree with an absent index,
    # as the checkout at the end of a clone does: regular and executable
    # files, symbolic links (created last, so no file is written through
    # one) and empty directories for submodules, then a matching index.
    # Existing files are never replaced.
    protected def populate_worktree(commit_oid : String, *, max_files : Int32 = 1_000_000,
                                    max_object_bytes : Int32 = 268_435_456,
                                    check : Proc(Nil)? = nil) : Int32
      require_worktree!
      check!
      root = work_tree.not_nil!
      raise Error.new("Git worktree already has an index") if File.exists?(File.join(@git_dir, "index"))
      walker = History::RevisionWalker.new(self, max_object_bytes: max_object_bytes, check: check)
      tree = walker.commit_node(commit_oid).tree
      entries = [] of {String, String, String}
      stack = [{tree, ""}]
      until stack.empty?
        check.try &.call
        oid, prefix = stack.pop
        kind, raw = object(oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git object #{oid} is not a tree") unless kind == "tree"
        Tree.each_entry(raw, @object_format) do |mode, name, entry_oid|
          path = prefix.empty? ? name : "#{prefix}/#{name}"
          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
          if mode == "40000"
            stack << {entry_oid, path}
          else
            entries << {path, mode, entry_oid}
            raise Error.new("Git checkout entry budget exceeded") if entries.size > max_files
          end
        end
      end
      entries.sort_by! { |entry| entry[0] }
      created = Set(String).new
      links = [] of {String, String}
      edits = [] of Index::Edit
      entries.each do |path, mode, oid|
        check.try &.call
        ensure_parent_directories(root, path, created)
        destination = File.join(root, path)
        case mode
        when "100644", "100755", "100664"
          kind, data = object(oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git checkout entry #{path} is not a blob") unless kind == "blob"
          fd = LibC.open(destination, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW,
            mode == "100755" ? 0o777 : 0o666)
          raise Error.new("Git checkout cannot create #{path}") if fd < 0
          io = IO::FileDescriptor.new(fd)
          begin
            io.write(data.to_slice)
          ensure
            io.close
          end
          normalized_mode = mode == "100755" ? "100755" : "100644"
          edits << Index::Put.new(path, normalized_mode, oid, Index.stat_for(destination, normalized_mode))
        when "120000"
          kind, data = object(oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git checkout entry #{path} is not a blob") unless kind == "blob"
          raise Error.new("Git symlink #{path} has an invalid target") if data.empty? || data.includes?('\0')
          links << {path, data}
          edits << Index::Put.new(path, "120000", oid)
        when "160000"
          Dir.mkdir(destination, 0o777)
          edits << Index::Put.new(path, "160000", oid)
        else
          raise Error.new("unsupported Git tree mode #{mode} at #{path}")
        end
      end
      links.each do |path, target|
        check.try &.call
        File.symlink(target, File.join(root, path))
      end
      unless edits.empty?
        image = @index.prepare_changes(edits, max_bytes: Int32::MAX // 2, max_entries: max_files + 1, check: check)
        @index.publish_image(image, max_bytes: Int32::MAX // 2, check: check)
      end
      entries.size
    rescue ex : File::Error | IO::Error
      raise Error.new("Git checkout failed: #{ex.class}: #{ex.message}")
    end

    private def ensure_parent_directories(root : String, path : String, created : Set(String)) : Nil
      components = path.split('/')
      current = ""
      components[0...-1].each do |component|
        current = current.empty? ? component : "#{current}/#{component}"
        next if created.includes?(current)
        full = File.join(root, current)
        if info = File.info?(full, follow_symlinks: false)
          raise Error.new("Git checkout path #{current} is not a directory") unless info.directory?
        else
          Dir.mkdir(full, 0o777)
        end
        created << current
      end
    end
  end
end
