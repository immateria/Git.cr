module Git
  # A local branch as `git branch -vv` reports it.
  record BranchInfo, name : String, oid : String, current : Bool,
    upstream : String?, ahead : Int32?, behind : Int32? do
    def ref : String
      "refs/heads/#{name}"
    end
  end

  # How a pull integrates the fetched upstream.
  enum PullMode
    # Only fast-forward; refuse diverged histories (`pull --ff-only`).
    FastForwardOnly
    # Fast-forward when possible, else a merge commit (`pull --no-rebase`).
    Merge
  end

  record PullResult, fetch : FetchResult, previous : String?, current : String?,
    action : Symbol, merge : Merge::Result? = nil

  class Repository
    # Local branches, with upstream tracking counts (`git branch -vv`).
    def branches(*, tracking : Bool = true, check : Proc(Nil)? = nil) : Array(BranchInfo)
      current = head[0]
      references("refs/heads/").compact_map do |ref|
        oid = ref.oid || next
        name = ref.name.byte_slice(11)
        upstream = nil.as(String?)
        ahead = nil.as(Int32?)
        behind = nil.as(Int32?)
        if tracking && (configured = branch_upstream(name))
          upstream = upstream_tracking_ref(configured[0], configured[1])
          if upstream && (other = resolve_ref?(upstream))
            walker = Reachability::Walker.new(self, check: check)
            ahead = walker.commits([oid], [other]).size
            behind = Reachability::Walker.new(self, check: check).commits([other], [oid]).size
          end
        end
        BranchInfo.new(name, oid, ref.name == current, upstream, ahead, behind)
      end
    end

    # `git branch -d/-D`. Without force the branch must be merged into its
    # upstream (or HEAD when it has none). The checked-out branch is
    # refused. Its reflog and branch.<name>.* configuration go with it.
    def delete_branch(name : String, *, force : Bool = false, check : Proc(Nil)? = nil) : String
      check!
      ref = new_branch_ref(name)
      oid = resolve_ref?(ref) || raise Error.new("Git branch #{name} not found")
      raise Error.new("Git cannot delete the checked-out branch #{name}") if head[0] == ref && !bare?
      unless force
        base = branch_upstream(name).try { |remote_name, merge| upstream_tracking_ref(remote_name, merge).try { |tracking| resolve_ref?(tracking) } } || head[1]
        merged = base && (base == oid || Reachability::Walker.new(self, check: check).ancestor?(oid, base))
        raise Error.new("Git branch #{name} is not fully merged") unless merged
      end
      delete_ref(ref, expected_oid: oid, check: check)
      File.delete?(File.join(@common, "logs", ref))
      Config::FileEditor.remove_section(local_config_path, "branch.#{name}")
      oid
    end

    # `git branch -m`: the ref, its reflog, its configuration and HEAD (when
    # it is checked out) move to the new name.
    def rename_branch(old_name : String, new_name : String, *, force : Bool = false,
                      check : Proc(Nil)? = nil) : Nil
      check!
      old_ref = new_branch_ref(old_name)
      new_ref = new_branch_ref(new_name)
      oid = resolve_ref?(old_ref) || raise Error.new("Git branch #{old_name} not found")
      return if old_ref == new_ref
      existing = resolve_ref?(new_ref)
      raise Error.new("Git branch #{new_name} already exists") if existing && !force
      changes = [] of References::Change
      changes << References::Update.new(new_ref, oid, existing)
      changes << References::Delete.new(old_ref, oid)
      old_log = File.join(@common, "logs", old_ref)
      saved_log = File.exists?(old_log) ? File.read(old_log) : nil
      change_refs(changes, check: check)
      if log = saved_log
        destination = File.join(@common, "logs", new_ref)
        Dir.mkdir_p(File.dirname(destination))
        File.write(destination, log)
      end
      set_symbolic_ref("HEAD", new_ref) if head[0] == old_ref
      Config::FileEditor.remove_section(local_config_path, "branch.#{new_name}") if force
      Config::FileEditor.rename_section(local_config_path, "branch.#{old_name}", "branch.#{new_name}")
    end

    # `git tag -d`.
    def delete_tag(name : String, *, check : Proc(Nil)? = nil) : String
      ref = "refs/tags/#{name}"
      raise Error.new("invalid Git tag name") unless RefName.valid?(ref)
      oid = resolve_ref?(ref) || raise Error.new("Git tag #{name} not found")
      delete_ref(ref, expected_oid: oid, check: check)
      oid
    end

    # Tag names and the objects they name (`git tag -l`).
    def tags : Array({String, String})
      references("refs/tags/").compact_map { |ref| ref.oid.try { |oid| {ref.name.byte_slice(10), oid} } }
    end

    # `git pull`: fetch the current branch's upstream, then fast-forward or
    # merge it. Merges use the native three-way merge; a conflicted merge
    # stops with Git's merge state for merge_continue or merge_abort.
    def pull(*, mode : PullMode = PullMode::FastForwardOnly, transport : Transport::Base? = nil,
             author : Signature? = nil, committer : Signature? = nil,
             actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
             max_entries : Int32 = 100_000, max_total_bytes : Int64 = 1_073_741_824,
             check : Proc(Nil)? = nil) : PullResult
      require_worktree!
      branch_ref = head[0] || raise Error.new("Git pull needs a checked-out branch")
      raise Error.new("Git pull needs a branch") unless branch_ref.starts_with?("refs/heads/")
      branch = branch_ref.byte_slice(11)
      remote_name, merge_ref = branch_upstream(branch) || raise Error.new("Git branch #{branch} has no upstream")
      fetched = fetch(remote_name, transport: transport, actor: actor, progress: progress, check: check)
      tracking = upstream_tracking_ref(remote_name, merge_ref) || raise Error.new("Git upstream #{merge_ref} is not fetched")
      target = resolve_ref?(tracking) || raise Error.new("Git upstream #{tracking} does not exist")
      previous = head[1]
      if previous.nil?
        update_ref(branch_ref, target, expected_oid: nil, max_object_bytes: 268_435_456)
        populate_worktree(target, max_files: max_entries, check: check)
        return PullResult.new(fetched, nil, target, :initial)
      end
      return PullResult.new(fetched, previous, previous, :up_to_date) if previous == target
      walker = Reachability::Walker.new(self, check: check)
      return PullResult.new(fetched, previous, previous, :up_to_date) if walker.ancestor?(target, previous)
      log = actor.try { |who| References::LogEntry.new(who, "pull: Fast-forward") }
      if walker.ancestor?(previous, target)
        merge_fast_forward(target, log: log, max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2,
          max_total_bytes: max_total_bytes, max_entries: Math.min(max_entries, @max_search_entries), check: check)
        return PullResult.new(fetched, previous, target, :fast_forward)
      end
      raise Error.new("Git pull cannot fast-forward #{branch}: histories diverged") if mode.fast_forward_only?
      who = author || raise Error.new("Git pull merge needs an author")
      message = "Merge branch '#{merge_ref.sub(/\Arefs\/heads\//, "")}' of #{remote(remote_name).url}\n"
      result = merge_three_way(target, author: who, committer: committer || who, message: message,
        max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2, max_total_bytes: max_total_bytes,
        max_entries: Math.min(max_entries, @max_search_entries), check: check)
      PullResult.new(fetched, previous, head[1], :merge, result)
    end
  end
end
