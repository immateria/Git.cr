require "file_utils"

module Git
  class Repository
    # `git clone`: create a repository at path (an empty or missing
    # directory), fetch from source, create the default (or named) branch
    # with its upstream and check it out. source is a URL or path, or an
    # explicitly configured transport (then url names it in the config).
    # A remote HEAD that is not a branch is cloned detached, as is a tag
    # given as branch.
    def self.clone(source : String | Transport, path : String, *,
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
      created = false
      if File.exists?(target)
        raise Error.new("Git clone destination #{path} exists and is not an empty directory") unless Dir.exists?(target) && Dir.empty?(target)
      else
        Dir.mkdir_p(target)
        created = true
      end
      begin
        clone_into(transport, target, stored_url, bare: bare, branch: branch, depth: depth,
          remote_name: remote_name, checkout: checkout, tags: tags, actor: actor,
          progress: progress, max_files: max_files, max_search_entries: max_search_entries,
          check: check)
      rescue ex
        # As Git does, remove what the failed clone wrote: the directory it
        # created, or the contents of the empty directory it was given.
        if created
          FileUtils.rm_rf(target)
        else
          Dir.children(target).each { |child| FileUtils.rm_rf(File.join(target, child)) } if Dir.exists?(target)
        end
        raise ex
      end
    end

    private def self.clone_into(transport : Transport, target : String, stored_url : String, *,
                                bare : Bool, branch : String?, depth : Int32?, remote_name : String,
                                checkout : Bool, tags : Remote::TagMode, actor : Signature?,
                                progress : Proc(String, Nil)?, max_files : Int32,
                                max_search_entries : Int32, check : Proc(Nil)?) : Repository
      # Learn the object format and the remote HEAD before creating anything.
      connection = transport.connect(Transport::Service::UploadPack)
      format, advertised = begin
        client = Protocol::UploadPack::Client.new(connection)
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
        Config::FileEditor.set(File.join(repository.common_dir, "config"), "remote.#{remote_name}.url", stored_url)
      else
        repository.add_remote(remote_name, stored_url, tag_mode: tags)
      end
      refspecs = bare ? ["+refs/heads/*:refs/heads/*"] : nil
      # Like git clone, a full clone takes every tag the remote has, not only
      # those reachable from its branches, while the remote keeps following
      # tags afterwards; a shallow clone (single-branch in Git) only follows.
      initial_tags = tags.auto? && depth.nil? ? Remote::TagMode::All : tags
      result = repository.fetch(remote_name, refspecs, transport: transport, depth: depth,
        tags: initial_tags, actor: actor, progress: progress, write_fetch_head: false,
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
      if checkout && !bare && (commit = repository.head_ref_and_oid[1])
        repository.populate_worktree(commit, max_files: max_files, check: check)
      end
      repository
    end

    protected def start_cloned_branch(name : String, oid : String, remote_name : String,
                                      log : References::LogEntry?) : Nil
      ref = "refs/heads/#{name}"
      update_ref(ref, oid, expected_oid: nil, log: log, max_object_bytes: 268_435_456) unless resolve_ref?(ref)
      set_branch_upstream(name, remote_name, ref)
      set_symbolic_ref("HEAD", ref)
    end
  end
end
