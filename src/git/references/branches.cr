module Git
  # A local branch as `git branch -vv` reports it: where it points, whether
  # it is checked out, its configured upstream and, when the upstream's
  # remote-tracking ref exists, how far the two have diverged.
  struct Branch
    # A branch's upstream configuration (branch.<name>.remote and .merge).
    # A remote of "." means another branch in this repository.
    record Upstream, remote : String, merge_ref : String

    getter name : String
    getter oid : String
    getter? current : Bool
    getter upstream : Upstream?
    # The remote-tracking ref that follows the upstream, if configured.
    getter tracking_ref : String?
    # Commits only on this branch, and only on its tracking ref.
    getter ahead : Int32?
    getter behind : Int32?

    def initialize(@name : String, @oid : String, @current : Bool, @upstream : Upstream? = nil,
                   @tracking_ref : String? = nil, @ahead : Int32? = nil, @behind : Int32? = nil)
    end

    def ref : String
      "refs/heads/#{@name}"
    end
  end

  # A repository's local branches (`git branch`). Obtained from
  # Repository#branches.
  struct Branches
    def initialize(@repository : Repository)
    end

    # Local branches sorted by name. With tracking, upstreams are read and
    # ahead/behind counted against their tracking refs. merged, no_merged and
    # contains filter branches by commit ancestry (`--merged`, `--no-merged`,
    # `--contains`).
    def list(*, tracking : Bool = true, merged : String? = nil,
             no_merged : String? = nil, contains : String? = nil,
             check : Proc(Nil)? = nil) : Array(Branch)
      @repository.list_branches(tracking: tracking, merged: merged,
        no_merged: no_merged, contains: contains, check: check)
    end

    # `git branch <name> [<from>]`: create a branch at a commit without
    # switching to it. Refuses an existing name. With track, the new branch
    # gets an upstream as branch.autoSetupMerge says (by default, when from
    # is a remote-tracking branch). With actor, its reflog gets Git's
    # "branch: Created from <from>". Returns the commit ID.
    def create(name : String, *, from : String = "HEAD", track : Bool = true,
               actor : Signature? = nil, max_object_bytes : Int32 = 8_388_608,
               check : Proc(Nil)? = nil) : String
      @repository.create_branch(name, from: from, track: track, actor: actor,
        max_object_bytes: max_object_bytes, check: check)
    end

    # `git branch -d` (or `-D` with force). Without force the branch must be
    # merged into its upstream, or HEAD when it has none. The checked-out
    # branch is refused. Its reflog and configuration go with it. Returns
    # the commit it pointed at.
    def delete(name : String, *, force : Bool = false, check : Proc(Nil)? = nil) : String
      @repository.delete_branch(name, force: force, check: check)
    end

    # `git branch -m` (`-M` with force): the ref, its reflog, its
    # configuration and HEAD, when it is checked out, move to the new name.
    def rename(old_name : String, new_name : String, *, force : Bool = false,
               check : Proc(Nil)? = nil) : Nil
      @repository.rename_branch(old_name, new_name, force: force, check: check)
    end

    # `git branch -c` (`-C` with force): copy the branch's ref, its reflog
    # and its configuration to a new branch name. With actor, the new reflog
    # gets Git's "Branch: copied refs/heads/<old> to refs/heads/<new>".
    def copy(old_name : String, new_name : String, *, force : Bool = false,
             actor : Signature? = nil, check : Proc(Nil)? = nil) : Nil
      @repository.copy_branch(old_name, new_name, force: force, actor: actor, check: check)
    end

    # The branch's configured upstream, or nil.
    def upstream(name : String) : Branch::Upstream?
      @repository.branch_upstream(name).try { |remote, merge_ref| Branch::Upstream.new(remote, merge_ref) }
    end

    # `git branch --set-upstream-to`.
    def set_upstream(name : String, upstream : Branch::Upstream) : Nil
      @repository.set_branch_upstream(name, upstream.remote, upstream.merge_ref)
    end

    # The remote-tracking ref of the branch's upstream (`<branch>@{upstream}`),
    # or nil when it has none.
    def tracking_ref(name : String) : String?
      upstream = @repository.branch_upstream(name) || return nil
      @repository.upstream_tracking_ref(upstream[0], upstream[1])
    end
  end

  class Repository
    # The repository's local branches.
    def branches : Branches
      Branches.new(self)
    end

    # Create a branch at an existing commit, without switching HEAD or
    # touching the worktree. A nil expected old OID ensures create-only
    # semantics even if the name exists only in packed-refs.
    protected def create_branch(name : String, *, from : String = "HEAD", track : Bool = true,
                                actor : Signature? = nil,
                                max_object_bytes : Int32 = 8_388_608,
                                check : Proc(Nil)? = nil) : String
      reference = new_branch_ref(name)
      target = History.resolve_commit(self, from, max_object_bytes, check)
      upstream = track ? start_point_upstream(name, from) : nil
      log = actor.try { |who| References::LogEntry.new(who, "branch: Created from #{from}") }
      update_ref(reference, target, expected_oid: nil, log: log,
        max_object_bytes: max_object_bytes, check: check)
      upstream.try { |remote_name, merge_ref| set_branch_upstream(name, remote_name, merge_ref) }
      target
    end

    # The upstream Git gives a new branch started at from, following
    # branch.autoSetupMerge: by default (true) only a remote-tracking start
    # point is tracked, "always" also tracks a local branch (remote "."),
    # "simple" needs the remote branch to have the new branch's name,
    # "inherit" copies from's own upstream, and false tracks nothing.
    protected def start_point_upstream(name : String, from : String) : {String, String}?
      mode = local_config.value?("branch.autoSetupMerge").try(&.downcase) || "true"
      return nil if {"false", "no", "off", "0"}.includes?(mode)
      full = expand_ref(from) || return nil
      if mode == "inherit"
        return full.starts_with?("refs/heads/") ? branch_upstream(full.byte_slice(11)) : nil
      end
      if full.starts_with?("refs/heads/")
        return mode == "always" ? {".", full} : nil
      end
      return nil unless full.starts_with?("refs/remotes/")
      found = [] of {String, String}
      remote_names.each do |remote_name|
        next unless remote = remote?(remote_name)
        remote.fetch_refspecs.each do |spec|
          next if spec.negative?
          if source = spec.map_destination(full)
            found << {remote_name, source}
          end
        end
      end
      found.uniq!
      raise Error.new("Git cannot track #{full}: more than one remote maps to it") if found.size > 1
      upstream = found.first? || return nil
      return nil if mode == "simple" && upstream[1] != "refs/heads/#{name}"
      upstream
    end

    # Local branches, with upstream tracking counts (`git branch -vv`) and
    # optional `--merged`, `--no-merged` and `--contains` filters.
    protected def list_branches(*, tracking : Bool = true, merged : String? = nil,
                                no_merged : String? = nil, contains : String? = nil,
                                check : Proc(Nil)? = nil) : Array(Branch)
      current = head_ref_and_oid[0]
      walker = History::RevisionWalker.new(self, check: check)
      merged_oid = merged.try { |rev| History.resolve_commit(self, rev, 8_388_608, check) }
      no_merged_oid = no_merged.try { |rev| History.resolve_commit(self, rev, 8_388_608, check) }
      contains_oid = contains.try { |rev| History.resolve_commit(self, rev, 8_388_608, check) }
      references("refs/heads/").compact_map do |ref|
        oid = ref.oid || next
        if target = merged_oid
          next unless oid == target || walker.ancestor?(oid, target)
        end
        if target = no_merged_oid
          next if oid == target || walker.ancestor?(oid, target)
        end
        if target = contains_oid
          next unless oid == target || walker.ancestor?(target, oid)
        end
        name = ref.name.byte_slice(11)
        next Branch.new(name, oid, ref.name == current) unless tracking
        configured = branch_upstream(name)
        upstream = configured.try { |remote, merge_ref| Branch::Upstream.new(remote, merge_ref) }
        tracking_ref = configured.try { |remote, merge_ref| upstream_tracking_ref(remote, merge_ref) }
        ahead = nil.as(Int32?)
        behind = nil.as(Int32?)
        if tracking_ref && (other = resolve_ref?(tracking_ref))
          ahead = walker.commits([oid], [other]).size
          behind = walker.commits([other], [oid]).size
        end
        Branch.new(name, oid, ref.name == current, upstream, tracking_ref, ahead, behind)
      end
    end

    # `git branch -d/-D`. Without force the branch must be merged into its
    # upstream (or HEAD when it has none). The checked-out branch is
    # refused. Its reflog and branch.<name>.* configuration go with it.
    protected def delete_branch(name : String, *, force : Bool = false, check : Proc(Nil)? = nil) : String
      check!
      ref = new_branch_ref(name)
      oid = resolve_ref?(ref) || raise Error.new("Git branch #{name} not found")
      raise Error.new("Git cannot delete the checked-out branch #{name}") if head_ref_and_oid[0] == ref && !bare?
      unless force
        upstream_oid = branch_upstream(name).try { |remote_name, merge| upstream_tracking_ref(remote_name, merge).try { |tracking| resolve_ref?(tracking) } }
        walker = History::RevisionWalker.new(self, check: check)
        merged = [upstream_oid, head_ref_and_oid[1]].compact.any? do |base|
          base == oid || walker.ancestor?(oid, base)
        end
        raise Error.new("Git branch #{name} is not fully merged") unless merged
      end
      delete_ref(ref, expected_oid: oid, check: check)
      File.delete?(File.join(@common, "logs", ref))
      Config::FileEditor.remove_section(local_config_path, "branch.#{name}")
      oid
    end

    # `git branch -m`: the ref, its reflog, its configuration and HEAD (when
    # it is checked out) move to the new name.
    protected def rename_branch(old_name : String, new_name : String, *, force : Bool = false,
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
      set_symbolic_ref("HEAD", new_ref) if head_ref_and_oid[0] == old_ref
      Config::FileEditor.remove_section(local_config_path, "branch.#{new_name}") if force
      Config::FileEditor.rename_section(local_config_path, "branch.#{old_name}", "branch.#{new_name}")
    end

    # `git branch -c` (`-C` with force): copy a branch's ref, its reflog and
    # its branch.<name>.* configuration to a new branch name.
    protected def copy_branch(old_name : String, new_name : String, *, force : Bool = false,
                              actor : Signature? = nil, check : Proc(Nil)? = nil) : Nil
      check!
      old_ref = new_branch_ref(old_name)
      new_ref = new_branch_ref(new_name)
      oid = resolve_ref?(old_ref) || raise Error.new("Git branch #{old_name} not found")
      existing = resolve_ref?(new_ref)
      raise Error.new("Git branch #{new_name} already exists") if (existing || old_ref == new_ref) && !force
      return if old_ref == new_ref
      old_log = File.join(@common, "logs", old_ref)
      saved_log = File.exists?(old_log) ? File.read(old_log) : nil
      update_ref(new_ref, oid, expected_oid: existing, check: check)
      destination = File.join(@common, "logs", new_ref)
      if log_bytes = saved_log
        Dir.mkdir_p(File.dirname(destination))
        File.write(destination, log_bytes)
      elsif force
        File.delete?(destination)
      end
      if who = actor
        entry = References::LogEntry.new(who, "Branch: copied #{old_ref} to #{new_ref}")
        References::Transaction.append_log(@common, new_ref, entry.encode(oid, oid))
      end
      Config::FileEditor.remove_section(local_config_path, "branch.#{new_name}") if force
      Config::FileEditor.copy_section(local_config_path, "branch.#{old_name}", "branch.#{new_name}")
    end

    private def new_branch_ref(name : String) : String
      ref = "refs/heads/#{name}"
      unless !name.empty? && !name.starts_with?('-') && RefName.valid?(ref)
        raise Error.new("invalid Git branch name")
      end
      ref
    end
  end
end
