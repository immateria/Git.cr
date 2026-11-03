module Git
  class Repository
    # `git clone`: create a repository at path (an empty or missing
    # directory), fetch from source, create the default (or named) branch
    # with its upstream and check it out. source is a URL or path, or an
    # explicitly configured transport (then url names it in the config).
    # A remote HEAD that is not a branch is cloned detached, as is a tag
    # given as branch.
    def self.clone(source : String | Transport::Base, path : String, *,
                   url : String? = nil, bare : Bool = false, branch : String? = nil,
                   depth : Int32? = nil, remote_name : String = "origin",
                   checkout : Bool = true, tags : Remote::TagMode = Remote::TagMode::Auto,
                   actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
                   max_files : Int32 = 1_000_000,
                   max_search_entries : Int32 = 1_000_000,
                   check : Proc(Nil)? = nil) : Repository
      transport = source.is_a?(String) ? Transport.for_url(source) : source
      stored_url = url || (source.is_a?(String) ? source : transport.url)
      if transport.is_a?(Transport::Local) && !stored_url.includes?("://")
        stored_url = File.expand_path(stored_url)
      end
      raise Error.new("invalid Git remote name #{remote_name.inspect}") unless Remote.valid_name?(remote_name)
      target = File.expand_path(path)
      if File.exists?(target)
        raise Error.new("Git clone destination #{path} exists and is not an empty directory") unless Dir.exists?(target) && Dir.empty?(target)
      else
        Dir.mkdir_p(target)
      end

      # Learn the object format and the remote HEAD before creating anything.
      connection = transport.connect(Transport::Service::UploadPack)
      format, advertised = begin
        client = Protocol::V2Client.new(connection)
        {client.object_format, client.ls_refs(["HEAD", "refs/heads/", "refs/tags/"])}
      ensure
        connection.close
      end
      remote_head = advertised.find { |ref| ref.name == "HEAD" }
      default_branch = remote_head.try(&.symref_target).try do |ref|
        ref.starts_with?("refs/heads/") ? ref.byte_slice(11) : nil
      end
      if default_branch.nil? && (head_oid = remote_head.try(&.oid))
        # A detached remote HEAD: prefer a branch at the same commit.
        candidates = advertised.select { |ref| ref.name.starts_with?("refs/heads/") && ref.oid == head_oid }
        chosen = candidates.find { |ref| ref.name == "refs/heads/main" || ref.name == "refs/heads/master" } || candidates.first?
        default_branch = chosen.try(&.name.byte_slice(11))
      end
      initial = branch || default_branch || "main"
      initial = "main" unless RefName.valid?("refs/heads/#{initial}")
      repository = init(target, bare: bare, initial_branch: initial, object_format: format, check: check)
      repository = new(target, max_search_entries: max_search_entries)
      if bare
        Config::FileEditor.set(File.join(repository.common_directory, "config"), "remote.#{remote_name}.url", stored_url)
      else
        repository.add_remote(remote_name, stored_url, tag_mode: tags)
      end
      refspecs = bare ? ["+refs/heads/*:refs/heads/*"] : nil
      result = repository.fetch(remote_name, refspecs, transport: transport, depth: depth,
        tags: tags, actor: actor, progress: progress, write_fetch_head: false,
        update_head_ok: true, check: check)
      tracking_prefix = "refs/remotes/#{remote_name}/"
      branch_source = ->(name : String) { bare ? "refs/heads/#{name}" : "#{tracking_prefix}#{name}" }

      if !bare && default_branch && repository.resolve_ref?(branch_source.call(default_branch))
        repository.set_symbolic_ref("#{tracking_prefix}HEAD", branch_source.call(default_branch))
      end

      log = actor.try { |who| References::LogEntry.new(who, "clone: from #{stored_url}") }
      detached = nil.as(String?)
      if name = branch
        if oid = repository.resolve_ref?(branch_source.call(name))
          repository.start_cloned_branch(name, oid, remote_name, log) unless bare
        elsif tag = result.remote_refs.find { |ref| ref.name == "refs/tags/#{name}" }
          detached = tag.peeled || tag.oid
        else
          raise Error.new("Git remote branch #{name} not found in upstream #{remote_name}")
        end
      elsif default_branch
        if oid = repository.resolve_ref?(branch_source.call(default_branch))
          repository.start_cloned_branch(default_branch, oid, remote_name, log) unless bare
        end
      elsif head_oid = remote_head.try(&.oid)
        detached = head_oid
      end
      if commit = detached
        repository.detach_head(commit)
      end
      if checkout && !bare && (commit = repository.head[1])
        repository.populate_worktree(commit, max_files: max_files, check: check)
      end
      repository
    end

    # The common Git directory (objects, refs, config).
    def common_directory : String
      @common
    end

    # The Git directory of this worktree (HEAD, index).
    def git_directory : String
      @git_dir
    end

    protected def start_cloned_branch(name : String, oid : String, remote_name : String,
                                      log : References::LogEntry?) : Nil
      ref = "refs/heads/#{name}"
      update_ref(ref, oid, expected_oid: nil, log: log, max_object_bytes: 268_435_456) unless resolve_ref?(ref)
      set_branch_upstream(name, remote_name, ref)
      set_symbolic_ref("HEAD", ref)
    end

    # Point HEAD directly at a commit (a detached HEAD).
    def detach_head(oid : String) : Nil
      check!
      ObjectId.valid!(oid, @object_format)
      raise Error.new("Git object #{oid} is not a commit") unless object_header(oid)[0] == "commit"
      path = File.join(@git_dir, "HEAD")
      lock = path + ".lock"
      fd = LibC.open(lock, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC | LibC::O_NOFOLLOW, 0o644)
      raise Error.new("Git HEAD.lock exists or cannot be created") if fd < 0
      begin
        io = IO::FileDescriptor.new(fd)
        begin
          io.write("#{oid}\n".to_slice)
          io.flush
          io.fsync
        ensure
          io.close
        end
        File.rename(lock, path)
        lock = nil
      ensure
        lock.try { |stale| File.delete?(stale) }
      end
    end

    # Write a commit's tree into an empty worktree with an absent index,
    # as the checkout at the end of a clone does: regular and executable
    # files, symbolic links (created last, so no file is written through
    # one) and empty directories for submodules, then a matching index.
    # Existing files are never replaced.
    def populate_worktree(commit_oid : String, *, max_files : Int32 = 1_000_000,
                          max_object_bytes : Int32 = 268_435_456,
                          check : Proc(Nil)? = nil) : Int32
      require_worktree!
      check!
      root = work_tree.not_nil!
      raise Error.new("Git worktree already has an index") if File.exists?(File.join(@git_dir, "index"))
      walker = Reachability::Walker.new(self, max_object_bytes: max_object_bytes, check: check)
      tree = walker.commit_info(commit_oid).tree
      entries = [] of {String, String, String}
      stack = [{tree, ""}]
      until stack.empty?
        check.try &.call
        oid, prefix = stack.pop
        kind, raw = object(oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git object #{oid} is not a tree") unless kind == "tree"
        Reachability.each_tree_entry(raw, @object_format) do |mode, name, entry_oid|
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
          edits << Index::Put.new(path, mode == "100755" ? "100755" : "100644", oid)
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
