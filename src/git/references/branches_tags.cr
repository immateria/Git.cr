module Git
  module References
    # A local branch as `git branch -vv` reports it.
    record Branch, name : String, oid : String, current : Bool,
      upstream : String?, ahead : Int32?, behind : Int32? do
      def ref : String
        "refs/heads/#{name}"
      end
    end
  end

  class Repository
    # Create a branch at an existing commit, without switching HEAD or
    # touching the worktree. A nil expected old OID ensures create-only
    # semantics even if the name exists only in packed-refs.
    def create_branch(name : String, *, from : String = "HEAD",
                      log : References::LogEntry? = nil,
                      max_object_bytes : Int32 = 8_388_608,
                      check : Proc(Nil)? = nil) : String
      reference = new_branch_ref(name)
      target = History.resolve_commit(self, from, max_object_bytes, check)
      update_ref(reference, target, expected_oid: nil, log: log,
        max_object_bytes: max_object_bytes, check: check)
      target
    end

    # Create a new lightweight or annotated tag referring to a commit.
    # This is intentionally a commit-only first slice. For an annotated tag,
    # both a tagger and message must be supplied, and the object is written
    # before a create-only ref CAS; a failed CAS may leave an orphan object.
    def create_tag(name : String, *, from : String = "HEAD",
                   message : String? = nil, tagger : Signature? = nil,
                   max_object_bytes : Int32 = 8_388_608,
                   check : Proc(Nil)? = nil) : String
      ref = "refs/tags/#{name}"
      unless !name.empty? && !name.starts_with?('-') && RefName.valid?(ref)
        raise Error.new("invalid Git tag name")
      end
      raise Error.new("Git annotated tag requires both tagger and message") unless message.nil? == tagger.nil?
      target = History.resolve_commit(self, from, max_object_bytes, check)
      tagged = if text = message
                 write_tag(object: target, type: "commit", name: name,
                   message: text, tagger: tagger, max_bytes: max_object_bytes,
                   check: check)
               else
                 target
               end
      update_ref(ref, tagged, expected_oid: nil,
        max_object_bytes: max_object_bytes, check: check)
      tagged
    end

    # Local branches, with upstream tracking counts (`git branch -vv`).
    def branches(*, tracking : Bool = true, check : Proc(Nil)? = nil) : Array(References::Branch)
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
            walker = History::RevisionWalker.new(self, check: check)
            ahead = walker.commits([oid], [other]).size
            behind = History::RevisionWalker.new(self, check: check).commits([other], [oid]).size
          end
        end
        References::Branch.new(name, oid, ref.name == current, upstream, ahead, behind)
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
        merged = base && (base == oid || History::RevisionWalker.new(self, check: check).ancestor?(oid, base))
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

    private def new_branch_ref(name : String) : String
      ref = "refs/heads/#{name}"
      unless !name.empty? && !name.starts_with?('-') && RefName.valid?(ref)
        raise Error.new("invalid Git branch name")
      end
      ref
    end
  end
end
