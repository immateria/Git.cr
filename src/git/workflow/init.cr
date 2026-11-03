module Git
  class Repository
    # Create a new repository in an existing, explicitly selected directory.
    # This narrow, template-free initializer refuses any pre-existing .git,
    # and refuses nonempty bare destinations. It neither executes Git nor
    # imports HOME, environment configuration, identities, or hooks.
    #
    # Directory descriptors confine all creation to a pinned root and
    # new administrative tree. The newly created directory is deliberately
    # NOT rolled back after an I/O failure; callers must inspect a partial
    # initialization rather than silently removing another writer's files.
    def self.init(root : String, *, bare : Bool = false,
                  initial_branch : String = "main",
                  object_format : ObjectId::Format = ObjectId::Format::SHA1,
                  check : Proc(Nil)? = nil) : Repository
      branch_ref = "refs/heads/#{initial_branch}"
      unless !initial_branch.empty? && !initial_branch.starts_with?('-') &&
             RefName.valid?(branch_ref)
        raise Error.new("invalid Git initial branch")
      end
      chosen = File.expand_path(root)
      raise Error.new("Git init root must be an existing ordinary directory") unless Dir.exists?(chosen) &&
                                                                                     !File.symlink?(chosen) && File.realpath(chosen) == chosen
      check.try &.call
      outer = DescriptorPath::Directory.open(chosen)
      begin
        raise Error.new("Git init root changed") unless outer.attached_at?(chosen)
        if bare
          Dir.each_child(chosen) { |_| raise Error.new("Git bare init requires an empty directory") }
        else
          # A strict create-only operation; no reinitialization or reuse of
          # an existing administrative directory or gitfile is implicit.
          raise Error.new("Git repository metadata already exists") if outer.stat?(".git")
          outer.mkdir_new(".git", 0o755)
          outer.sync
        end
        admin = bare ? chosen : File.join(chosen, ".git")
        directory = bare ? outer : DescriptorPath::Directory.open(admin)
        begin
          raise Error.new("Git init root changed") unless outer.attached_at?(chosen)
          unless bare
            raise Error.new("Git init directory changed") unless directory.attached_at?(admin)
          end
          directory.mkdir_new("objects", 0o755)
          directory.mkdir_new("refs", 0o755)
          objects = directory.open_directory("objects")
          begin
            objects.mkdir_new("info", 0o755)
            objects.mkdir_new("pack", 0o755)
            objects.sync
          ensure
            objects.close
          end
          refs = directory.open_directory("refs")
          begin
            refs.mkdir_new("heads", 0o755)
            refs.mkdir_new("tags", 0o755)
            refs.sync
          ensure
            refs.close
          end
          version = object_format.sha256? ? 1 : 0
          check.try &.call
          # Git probes the new directory's file system and writes what it
          # finds into the config (create_default_files in Git 2.47.3's
          # setup.c), in this order. The config is made empty first: two of
          # the probes look at it.
          config_io = directory.open_file("config", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o644)
          begin
            filemode = init_filemode?(config_io)
            symlinks = init_symlinks?(directory)
            ignorecase = !directory.stat?("CoNfIg").nil?
            precomposed = init_precomposed_unicode?(directory)
            config = String.build do |io|
              io << "[core]\n\trepositoryformatversion = #{version}\n\tfilemode = #{filemode}\n"
              io << "\tbare = #{bare}\n"
              io << "\tlogallrefupdates = true\n" unless bare
              io << "\tsymlinks = false\n" unless symlinks
              io << "\tignorecase = true\n" if ignorecase
              io << "\tprecomposeunicode = #{precomposed}\n" unless precomposed.nil?
              if object_format.sha256?
                io << "[extensions]\n\tobjectformat = sha256\n"
              end
            end
            config_io.write(config.to_slice)
            config_io.flush
            config_io.fsync
          ensure
            config_io.close
          end
          check.try &.call
          io = directory.open_file("HEAD", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o644)
          begin
            io.write("ref: #{branch_ref}\n".to_slice)
            io.flush
            io.fsync
          ensure
            io.close
          end
          directory.sync
          raise Error.new("Git init root changed") unless outer.attached_at?(chosen)
          raise Error.new("Git init directory changed") unless directory.attached_at?(admin)
        ensure
          directory.close unless bare
        end
      ensure
        outer.close
      end
      new(chosen)
    end

    # Whether the file system keeps the owner's execute bit: Git flips it on
    # the new config and looks, and takes a config made executable already
    # as a file system that marks every file so.
    private def self.init_filemode?(config : IO::FileDescriptor) : Bool
      before = uninitialized LibC::Stat
      after = uninitialized LibC::Stat
      raise Error.new("Git init config unavailable") unless LibC.fstat(config.fd, pointerof(before)) == 0
      permissions = before.st_mode & 0o7777
      kept = LibC.fchmod(config.fd, permissions ^ LibC::S_IXUSR) == 0 &&
             LibC.fstat(config.fd, pointerof(after)) == 0 && after.st_mode != before.st_mode &&
             LibC.fchmod(config.fd, permissions) == 0
      kept && (before.st_mode & LibC::S_IXUSR) == 0
    end

    # Whether the file system makes symbolic links: Git makes one under a
    # fresh name, looks at it without following it, and removes it.
    private def self.init_symlinks?(directory : DescriptorPath::Directory) : Bool
      name = "t#{Random::Secure.hex(3)}"
      begin
        made = directory.symlink_new(name, "testing")
      rescue Error
        return false
      end
      directory.unlink(name)
      (made.st_mode & LibC::S_IFMT) == LibC::S_IFLNK
    end

    # Whether the file system finds a name written precomposed (NFC) under
    # its decomposed form (NFD), as Apple's do. Git probes it only on macOS,
    # and writes nothing when it cannot make the probe's file.
    private def self.init_precomposed_unicode?(directory : DescriptorPath::Directory) : Bool?
      {% if flag?(:darwin) %}
        precomposed = "ä"
        begin
          directory.open_file(precomposed, LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL, 0o600).close
        rescue Error
          return nil
        end
        found = begin
          !directory.stat?("ä").nil?
        rescue Error
          false
        end
        directory.unlink(precomposed)
        found
      {% else %}
        nil
      {% end %}
    end
  end
end
