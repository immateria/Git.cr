module Git
  # A configured remote (`[remote "<name>"]` in the repository config).
  class Remote
    enum TagMode
      # Follow tags that point into fetched history (Git's default).
      Auto
      # Fetch every tag (`--tags`, remote.<name>.tagOpt = --tags).
      All
      # Fetch no tags unless a refspec names them (`--no-tags`).
      None
    end

    getter name : String
    getter urls : Array(String)
    getter push_urls : Array(String)
    getter fetch_refspecs : Array(Remote::Refspec)
    getter push_refspecs : Array(Remote::Refspec)
    getter tag_mode : TagMode
    getter prune : Bool?

    def initialize(@name, @urls, @push_urls, @fetch_refspecs, @push_refspecs, @tag_mode, @prune)
    end

    def url : String
      @urls.first? || raise Error.new("Git remote #{@name} has no URL")
    end

    def push_url : String
      @push_urls.first? || url
    end

    def self.default_fetch_refspec(name : String) : String
      "+refs/heads/*:refs/remotes/#{name}/*"
    end

    # Git's valid_remote_name: refs/remotes/<name>/x must be a valid ref.
    def self.valid_name?(name : String) : Bool
      !name.empty? && !name.starts_with?('-') && RefName.valid?("refs/remotes/#{name}/test")
    end

    # The remote-tracking ref this remote's fetch refspecs store a remote
    # ref in (refs/heads/main to refs/remotes/origin/main), or nil.
    def tracking_ref(remote_ref : String) : String?
      @fetch_refspecs.each do |spec|
        next if spec.negative?
        if mapped = spec.map_source(remote_ref)
          return mapped
        end
      end
      nil
    end
  end

  class Repository
    private def local_config_path : String
      File.join(@common, "config")
    end

    private def local_config : Config
      Config.load([Config::Source.new(Config::Scope::Local, local_config_path)])
    end

    # Names of the configured remotes, in first-seen config order.
    protected def remote_names : Array(String)
      names = [] of String
      local_config.entries.each do |entry|
        next unless entry.name.starts_with?("remote.")
        dot = entry.name.rindex('.').not_nil!
        next if dot <= 7
        name = entry.name.byte_slice(7, dot - 7)
        names << name unless names.includes?(name)
      end
      names
    end

    # The named remote, or nil if it has no configuration.
    protected def remote?(name : String) : Remote?
      config = local_config
      prefix = "remote.#{name}."
      return nil unless config.entries.any? { |entry| entry.name.starts_with?(prefix) }
      values = ->(key : String) { config.values(prefix + key).compact }
      tag_mode = case config.value?(prefix + "tagopt")
                 when "--tags"    then Remote::TagMode::All
                 when "--no-tags" then Remote::TagMode::None
                 else                  Remote::TagMode::Auto
                 end
      Remote.new(name, values.call("url"), values.call("pushurl"),
        values.call("fetch").map { |spec| Remote::Refspec.parse(spec, fetch: true) },
        values.call("push").map { |spec| Remote::Refspec.parse(spec, fetch: false) },
        tag_mode, config.boolean?(prefix + "prune"))
    end

    protected def remote(name : String) : Remote
      remote?(name) || raise Error.new("Git remote #{name} is not configured")
    end

    # `git remote add`: url and the default (or given) fetch refspecs.
    protected def add_remote(name : String, url : String, *, fetch : Array(String)? = nil,
                             tag_mode : Remote::TagMode = Remote::TagMode::Auto) : Remote
      check!
      raise Error.new("invalid Git remote name #{name.inspect}") unless Remote.valid_name?(name)
      raise Error.new("Git remote #{name} already exists") if remote?(name)
      specs = fetch || [Remote.default_fetch_refspec(name)]
      specs.each { |spec| Remote::Refspec.parse(spec, fetch: true) }
      Config::FileEditor.set(local_config_path, "remote.#{name}.url", url)
      specs.each { |spec| Config::FileEditor.add(local_config_path, "remote.#{name}.fetch", spec) }
      case tag_mode
      in .all?  then Config::FileEditor.set(local_config_path, "remote.#{name}.tagOpt", "--tags")
      in .none? then Config::FileEditor.set(local_config_path, "remote.#{name}.tagOpt", "--no-tags")
      in .auto?
      end
      remote(name)
    end

    protected def set_remote_url(name : String, url : String, *, push : Bool = false) : Nil
      check!
      remote(name)
      Config::FileEditor.replace_all(local_config_path, "remote.#{name}.#{push ? "pushurl" : "url"}", url)
    end

    # `git remote remove`: the remote's configuration, its remote-tracking
    # refs and the branch upstream settings that name it.
    protected def remove_remote(name : String) : Nil
      check!
      existing = remote(name)
      Config::FileEditor.remove_section(local_config_path, "remote.#{name}")
      local_config.entries.each do |entry|
        next unless entry.name.starts_with?("branch.") && entry.name.ends_with?(".remote") && entry.value == name
        branch = entry.name.byte_slice(7, entry.name.bytesize - 14)
        ["remote", "merge"].each do |key|
          begin
            Config::FileEditor.unset_all(local_config_path, "branch.#{branch}.#{key}")
          rescue Error
          end
        end
      end
      tracking = existing.fetch_refspecs.compact_map(&.destination)
      references("refs/").each do |ref|
        next unless tracking.any? { |destination| Remote::Refspec.matches?(destination, ref.name, destination.includes?('*')) }
        if ref.symbolic?
          delete_symbolic_ref(ref.name)
        elsif oid = ref.oid
          delete_ref(ref.name, expected_oid: oid)
        end
      end
    end

    # `git remote rename`: configuration, default refspecs, tracking refs
    # and branch upstreams move to the new name.
    protected def rename_remote(old_name : String, new_name : String) : Nil
      check!
      raise Error.new("invalid Git remote name #{new_name.inspect}") unless Remote.valid_name?(new_name)
      raise Error.new("Git remote #{new_name} already exists") if remote?(new_name)
      existing = remote(old_name)
      Config::FileEditor.rename_section(local_config_path, "remote.#{old_name}", "remote.#{new_name}")
      old_default = Remote.default_fetch_refspec(old_name)
      if existing.fetch_refspecs.any? { |spec| spec.to_s == old_default }
        Config::FileEditor.unset_all(local_config_path, "remote.#{new_name}.fetch")
        existing.fetch_refspecs.each do |spec|
          text = spec.to_s == old_default ? Remote.default_fetch_refspec(new_name) : spec.to_s
          Config::FileEditor.add(local_config_path, "remote.#{new_name}.fetch", text)
        end
      end
      local_config.entries.each do |entry|
        next unless entry.name.starts_with?("branch.") && entry.name.ends_with?(".remote") && entry.value == old_name
        Config::FileEditor.set(local_config_path, entry.name, new_name)
      end
      old_prefix = "refs/remotes/#{old_name}/"
      new_prefix = "refs/remotes/#{new_name}/"
      refs = references(old_prefix)
      changes = [] of References::Change
      symbolic = [] of {String, String}
      refs.each do |ref|
        renamed = new_prefix + ref.name.byte_slice(old_prefix.bytesize)
        if target = ref.symref_target
          symbolic << {renamed, target.starts_with?(old_prefix) ? new_prefix + target.byte_slice(old_prefix.bytesize) : target}
          delete_symbolic_ref(ref.name)
        elsif oid = ref.oid
          changes << References::Update.new(renamed, oid, nil)
          changes << References::Delete.new(ref.name, oid)
        end
      end
      change_refs(changes, max_changes: changes.size) unless changes.empty?
      symbolic.each { |name, target| set_symbolic_ref(name, target) }
    end

    # The remote-tracking ref for a branch's upstream merge ref, by the
    # remote's fetch refspecs ("." is the local repository).
    protected def upstream_tracking_ref(remote_name : String, merge_ref : String) : String?
      return merge_ref if remote_name == "."
      remote?(remote_name).try(&.tracking_ref(merge_ref))
    end

    # The upstream of a local branch: {remote name, merge ref}.
    protected def branch_upstream(branch : String) : {String, String}?
      config = local_config
      remote_name = config.value?("branch.#{branch}.remote")
      merge = config.value?("branch.#{branch}.merge")
      remote_name && merge ? {remote_name, merge} : nil
    end

    # `git branch --set-upstream-to`: branch.<name>.remote and .merge.
    protected def set_branch_upstream(branch : String, remote_name : String, merge_ref : String) : Nil
      check!
      raise Error.new("invalid Git branch name") unless RefName.valid?("refs/heads/#{branch}")
      Config::FileEditor.set(local_config_path, "branch.#{branch}.remote", remote_name)
      Config::FileEditor.set(local_config_path, "branch.#{branch}.merge", merge_ref)
    end
  end
end
