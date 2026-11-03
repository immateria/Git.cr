module Git
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

    private def new_branch_ref(name : String) : String
      ref = "refs/heads/#{name}"
      unless !name.empty? && !name.starts_with?('-') && RefName.valid?(ref)
        raise Error.new("invalid Git branch name")
      end
      ref
    end
  end
end
