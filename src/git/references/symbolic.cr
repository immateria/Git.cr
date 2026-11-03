module Git
  class Repository
    # Point a symbolic ref (HEAD or refs/...) at target, as
    # `git symbolic-ref` does. The ref is written through an exclusive
    # .lock and renamed into place; target need not exist yet. With
    # expected_target the ref must currently point there; with create_only
    # it must not exist.
    protected def set_symbolic_ref(name : String, target : String, *, expected_target : String? = nil,
                                   create_only : Bool = false, check : Proc(Nil)? = nil) : Nil
      check!
      raise Error.new("invalid Git symbolic ref target") unless target.starts_with?("refs/") && RefName.valid?(target)
      path = symbolic_ref_path(name)
      if create_only
        raise Error.new("Git ref #{name} already exists") if File.info?(path, follow_symlinks: false)
      elsif expected = expected_target
        current = File.exists?(path) ? symbolic_ref?(name) : nil
        raise Error.new("Git symbolic ref #{name} changed (expected #{expected}, found #{current.inspect})") unless current == expected
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
    protected def delete_symbolic_ref(name : String) : Nil
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

    # Point HEAD directly at a commit (a detached HEAD).
    protected def detach_head(oid : String) : Nil
      check!
      ObjectId.valid!(oid, @object_format)
      raise Error.new("Git object #{oid} is not a commit") unless object_header(oid).type.commit?
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
  end
end
