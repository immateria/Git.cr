module Git
  # :nodoc:
  # Physical repository selection is intentionally separate from ref/object
  # interpretation. All non-default metadata locations must be explicitly
  # supplied by a trusted caller; no process environment is read implicitly.
  # A single Store pins this resolution and refuses a later redirection.
  class Location
    @ceiling : String?
    record Selection, root : String, git_dir : String, common : String,
      work_tree : String?, bare : Bool

    getter root : String
    getter git_dir : String
    getter common : String
    getter work_tree : String?
    getter? bare : Bool

    def initialize(@start : String, *, @git_dir_option : String? = nil,
                   @common_dir_option : String? = nil, @work_tree_option : String? = nil,
                   @linked_admin : String? = nil, @follow_gitfile : Bool = true,
                   @discover : Bool = false, @discovery_ceiling : String? = nil,
                   @before_config : Proc(Repository::Admission::Site, Nil)? = nil,
                   @before_implicit_bare : Proc(Nil)? = nil)
      @start_real = File.realpath(@start)
      raise Error.new("Git repository selection must start at a directory") unless Dir.exists?(@start_real)
      @ceiling = @discovery_ceiling.try { |value| File.realpath(value) }
      if ceiling = @ceiling
        raise Error.new("Git discovery ceiling does not contain start") unless within?(@start_real, ceiling)
      end
      if admin = @linked_admin
        raise ArgumentError.new("linked Git admin must be an absolute host-selected path") unless Path[admin].absolute?
      end
      @root = ""
      @git_dir = ""
      @common = ""
      @work_tree = nil.as(String?)
      @bare = false
      current = resolve
      @root = current.root
      @git_dir = current.git_dir
      @common = current.common
      @work_tree = current.work_tree
      @bare = current.bare
      @start_identity = File.info(@start_real, follow_symlinks: false)
      @git_identity = File.info(@git_dir, follow_symlinks: false)
      @common_identity = File.info(@common, follow_symlinks: false)
      @root_identity = File.info(@root, follow_symlinks: false)
    end

    def check! : Nil
      raise Error.new("Git repository starting directory moved") unless File.realpath(@start) == @start_real &&
                                                                        File.info(@start_real, follow_symlinks: false).same_file?(@start_identity)
      latest = resolve
      raise Error.new("Git repository metadata selection changed") unless latest == Selection.new(@root, @git_dir, @common, @work_tree, @bare)
      raise Error.new("Git repository metadata directory replaced") unless File.info(@git_dir, follow_symlinks: false).same_file?(@git_identity) &&
                                                                           File.info(@common, follow_symlinks: false).same_file?(@common_identity) &&
                                                                           File.info(@root, follow_symlinks: false).same_file?(@root_identity)
    rescue ex : File::Error
      raise Error.new("Git repository location changed or disappeared: #{ex.class}")
    end

    private def resolve : Selection
      selected_git = @git_dir_option.try { |path| absolute_from(@start_real, path) }
      selected_admin = @linked_admin.try { |path| absolute_from(@start_real, path) }
      if selected_git && selected_admin && selected_git != selected_admin
        raise Error.new("conflicting Git administrative directory selections")
      end
      selected_git ||= selected_admin
      explicit_git = !selected_git.nil?
      repository_root = if !explicit_git && @discover
                          find_repository_root(@start_real)
                        else
                          @start_real
                        end
      selected_worktree = @work_tree_option.try { |path| absolute_from(@start_real, path) }
      marker_root = selected_worktree || repository_root
      # The metadata search uses the cwd, not GIT_WORK_TREE. An explicitly
      # selected Git directory may bypass discovery entirely.
      dot_git = File.join(explicit_git ? marker_root : repository_root, ".git")
      # An explicit GIT_DIR takes precedence over .git. Otherwise ordinary
      # Git readers follow gitfiles; the adapter disables this without
      # a trusted host-selected administrative path.
      raise Error.new("Git metadata symlink refused") if (!explicit_git || selected_admin) && File.symlink?(dot_git)
      git_dir = if selected_git
                  selected_git
                elsif Dir.exists?(dot_git)
                  dot_git
                elsif File.file?(dot_git)
                  raise Error.new("external Git metadata needs a host-selected directory") unless @follow_gitfile
                  absolute_from(repository_root, read_pointer(dot_git, "gitdir: "))
                elsif bare_candidate?(repository_root)
                  # A bare candidate's core.bare must not be interpreted before
                  # the checked caller has assessed its physical ownership.
                  @before_config.try &.call(Repository::Admission::Site.new(repository_root,
                    repository_root, true, nil))
                  raise Error.new("Git metadata is missing") unless bare_repository?(repository_root)
                  @before_implicit_bare.try &.call
                  repository_root
                else
                  raise Error.new("Git metadata is missing")
                end
      verify_directory!(git_dir)
      if before_config = @before_config
        guessed_bare = selected_worktree.nil? && git_dir == repository_root
        gitfile = !explicit_git || selected_admin ? (File.file?(dot_git) ? dot_git : nil) : nil
        before_config.call(Repository::Admission::Site.new(guessed_bare ? git_dir : marker_root,
          git_dir, guessed_bare, gitfile))
      end
      if selected_admin && (git_dir == marker_root || within?(git_dir, marker_root))
        raise Error.new("linked Git metadata must be outside worktree")
      end
      if selected_admin
        # The original host-selected linked worktree capability must still
        # prove both forward and reverse links. Explicit GIT_DIR, by contrast,
        # intentionally overrides a different .git marker, like upstream Git.
        raise Error.new("linked Git worktree has no .git pointer") unless File.file?(dot_git)
        verify_gitfile!(dot_git, git_dir, marker_root)
      end
      raise Error.new("Git commondir symlink refused") if File.symlink?(File.join(git_dir, "commondir"))
      indicated_common = if File.file?(File.join(git_dir, "commondir"))
                           absolute_from(git_dir, read_pointer(File.join(git_dir, "commondir")))
                         else
                           git_dir
                         end
      # GIT_COMMON_DIR from the caller environment is cwd-relative;
      # only the commondir *file* is relative to GIT_DIR.
      common = @common_dir_option.try { |path| absolute_from(@start_real, path) } || indicated_common
      verify_directory!(common)
      if File.file?(File.join(git_dir, "gitdir"))
        backlink = absolute_from(git_dir, read_pointer(File.join(git_dir, "gitdir")))
        raise Error.new("Git worktree backlink mismatch") unless backlink == dot_git && File.file?(dot_git)
        verify_gitfile!(dot_git, git_dir, marker_root)
        unless File.basename(File.dirname(git_dir)) == "worktrees" &&
               File.dirname(File.dirname(git_dir)) == indicated_common
          raise Error.new("Git linked-worktree administrative layout mismatch")
        end
      elsif selected_admin && File.file?(File.join(git_dir, "commondir"))
        raise Error.new("Git linked-worktree backlink missing")
      end
      objects = File.join(common, "objects")
      verify_directory!(objects)
      core = read_core_selection(File.join(common, "config"))
      if !explicit_git && git_dir == repository_root && !core.bare
        raise Error.new("Git directory lacks bare repository configuration")
      end
      if !selected_worktree && core.bare
        return Selection.new(git_dir, git_dir, common, nil, true)
      end
      if core.worktree && !selected_worktree
        configured = absolute_from(git_dir, core.worktree.not_nil!)
        unless configured == repository_root
          raise Error.new("Git core.worktree requires explicit host-selected work_tree")
        end
      end
      worktree = selected_worktree || repository_root
      verify_directory!(worktree)
      Selection.new(worktree, git_dir, common, worktree, false)
    end

    private def find_repository_root(from : String) : String
      current = from
      loop do
        marker = File.join(current, ".git")
        raise Error.new("Git metadata symlink refused") if File.symlink?(marker)
        return current if Dir.exists?(marker) || File.file?(marker)
        if bare_candidate?(current)
          @before_config.try &.call(Repository::Admission::Site.new(current, current, true, nil))
          if bare_repository?(current)
            @before_implicit_bare.try &.call
            return current
          end
        end
        break if current == @ceiling || current == File.dirname(current)
        current = File.dirname(current)
      end
      raise Error.new("Git repository discovery found no repository")
    end

    private def bare_candidate?(path : String) : Bool
      File.file?(File.join(path, "HEAD")) && Dir.exists?(File.join(path, "objects")) &&
        File.file?(File.join(path, "config"))
    end

    private def bare_repository?(path : String) : Bool
      bare_candidate?(path) && read_core_selection(File.join(path, "config")).bare
    end

    record CoreSelection, bare : Bool, worktree : String?

    # Only selection-critical core values belong here. Full config layers,
    # quoting, includes, and protected-scope evaluation are P06 work.
    private def read_core_selection(config : String) : CoreSelection
      return CoreSelection.new(false, nil) unless File.file?(config) || File.symlink?(config)
      raw = read_small(config, 128 * 1024)
      section = ""
      bare = false
      worktree = nil.as(String?)
      raw.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?(';')
        if match = /\A\[([A-Za-z][A-Za-z0-9-]*)\]\z/.match(stripped)
          section = match[1].downcase
        elsif stripped.starts_with?('[')
          section = ""
        elsif section == "core"
          parts = stripped.split('=', 2)
          next unless parts.size == 2
          case parts[0].strip.downcase
          when "bare"
            bare = case parts[1].strip.downcase
                   when "true", "yes", "on", "1"  then true
                   when "false", "no", "off", "0" then false
                   else                                raise Error.new("invalid Git core.bare configuration")
                   end
          when "worktree"
            worktree = parts[1].strip
            raise Error.new("empty Git core.worktree configuration") if worktree.empty?
          end
        end
      end
      CoreSelection.new(bare, worktree)
    end

    private def verify_gitfile!(gitfile : String, admin : String, root : String) : Nil
      raise Error.new("Git metadata pointer mismatch") unless absolute_from(root, read_pointer(gitfile, "gitdir: ")) == admin
    end

    private def read_pointer(path : String, prefix : String = "") : String
      raw = read_small(path, 4096)
      line = raw.ends_with?('\n') ? raw.byte_slice(0, raw.bytesize - 1) : raw
      line = line.byte_slice(0, line.bytesize - 1) if line.ends_with?('\r')
      raise Error.new("invalid Git metadata pointer") if line.empty? || line.includes?('\0') || line.includes?('\n') || !line.starts_with?(prefix)
      value = line.byte_slice(prefix.bytesize, line.bytesize - prefix.bytesize)
      raise Error.new("empty Git metadata pointer") if value.empty?
      value
    end

    private def read_small(path : String, max_bytes : Int32) : String
      raise Error.new("Git metadata pointer symlink or nonregular file") if File.symlink?(path) || !File.file?(path) || File.realpath(path) != path
      buffer = IO::Memory.new
      File.open(path) { |f| IO.copy(f, buffer, max_bytes.to_i64 + 1) }
      raise Error.new("Git metadata pointer too large") if buffer.size > max_bytes
      buffer.to_s
    end

    private def verify_directory!(path : String) : Nil
      raise Error.new("Git metadata directory missing or redirected") unless Dir.exists?(path) && !File.symlink?(path) && File.realpath(path) == path
    end

    private def absolute_from(base : String, relative_or_absolute : String) : String
      raise Error.new("empty Git path selection") if relative_or_absolute.empty? || relative_or_absolute.includes?('\0')
      File.expand_path(relative_or_absolute, base)
    end

    private def within?(path : String, parent : String) : Bool
      path == parent || path.starts_with?(parent + File::SEPARATOR)
    end
  end
end
