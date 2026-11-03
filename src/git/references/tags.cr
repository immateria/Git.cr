module Git
  # A repository's tags (`git tag`). Obtained from Repository#tags.
  struct Tags
    def initialize(@repository : Repository)
    end

    # Every tag ref with the object it names, sorted by name.
    def list : Array(References::Ref)
      @repository.list_tags
    end

    # Create a lightweight tag, or an annotated one when message and tagger
    # are given, for a commit. Refuses an existing name. Returns what the
    # tag ref points at (the tag object for an annotated tag).
    def create(name : String, *, from : String = "HEAD", message : String? = nil,
               tagger : Signature? = nil, max_object_bytes : Int32 = 8_388_608,
               check : Proc(Nil)? = nil) : String
      @repository.create_tag(name, from: from, message: message, tagger: tagger,
        max_object_bytes: max_object_bytes, check: check)
    end

    # `git tag -d`. Returns the object the tag pointed at.
    def delete(name : String, *, check : Proc(Nil)? = nil) : String
      @repository.delete_tag(name, check: check)
    end
  end

  class Repository
    # The repository's tags.
    def tags : Tags
      Tags.new(self)
    end

    # Create a new lightweight or annotated tag referring to a commit.
    # This is intentionally a commit-only first slice. For an annotated tag,
    # both a tagger and message must be supplied, and the object is written
    # before a create-only ref CAS; a failed CAS may leave an orphan object.
    protected def create_tag(name : String, *, from : String = "HEAD",
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

    # `git tag -d`.
    protected def delete_tag(name : String, *, check : Proc(Nil)? = nil) : String
      ref = "refs/tags/#{name}"
      raise Error.new("invalid Git tag name") unless RefName.valid?(ref)
      oid = resolve_ref?(ref) || raise Error.new("Git tag #{name} not found")
      delete_ref(ref, expected_oid: oid, check: check)
      oid
    end

    protected def list_tags : Array(References::Ref)
      references("refs/tags/")
    end
  end
end
