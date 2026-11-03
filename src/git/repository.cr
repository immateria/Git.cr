require "set"

module Git
  # Public repository facade. Keep the established Git::Repository API and
  # index/worktree extension methods while storage owners remain independent.
  class Repository
    MAX_DEPTH = Metadata::MAX_DEPTH

    @max_search_entries : Int32
    @max_scan_bytes : Int32
    @common : String
    @git_dir : String
    getter root : String

    def initialize(root : String, *, linked_worktree_admin_dir : String? = nil,
                   git_dir : String? = nil, common_dir : String? = nil,
                   work_tree : String? = nil, follow_gitfile : Bool = true,
                   discover : Bool = false,
                   discovery_ceiling : String? = nil,
                   before_config : Proc(Admission::Site, Nil)? = nil,
                   before_implicit_bare : Proc(Nil)? = nil,
                   @max_scan_bytes : Int32 = 8_388_608, @max_search_entries : Int32 = 10_000)
      @metadata = Metadata.new(root, linked_worktree_admin_dir: linked_worktree_admin_dir,
        git_dir: git_dir, common_dir: common_dir, work_tree: work_tree,
        follow_gitfile: follow_gitfile, discover: discover, discovery_ceiling: discovery_ceiling,
        before_config: before_config, before_implicit_bare: before_implicit_bare,
        max_scan_bytes: @max_scan_bytes, max_search_entries: @max_search_entries)
      @object_format = @metadata.object_format
      @root = @metadata.root
      @common = @metadata.common
      @git_dir = @metadata.git_dir
      @object_database = ObjectDatabase.new(@common, @object_format)
      @head_tree = HeadTree.new(@metadata, @object_database, @max_search_entries, @object_format)
      @index = Index.new(@metadata, @head_tree, @object_database, @object_format, @max_search_entries)
      @worktree = WorkingTree.new(@root, @common, @index, @object_format, @max_scan_bytes, @max_search_entries)
    end

    # Interpret only the repository-placement variables supplied by a trusted
    # host. Process ENV is never consulted implicitly; configuration and the
    # remaining Git environment grammar belong to P06.
    def self.from_environment(cwd : String, variables : Hash(String, String), *,
                              discover : Bool = true, discovery_ceiling : String? = nil,
                              max_scan_bytes : Int32 = 8_388_608,
                              max_search_entries : Int32 = 10_000) : Repository
      new(cwd, git_dir: variables["GIT_DIR"]?, common_dir: variables["GIT_COMMON_DIR"]?,
        work_tree: variables["GIT_WORK_TREE"]?, discover: discover,
        discovery_ceiling: discovery_ceiling, max_scan_bytes: max_scan_bytes,
        max_search_entries: max_search_entries)
    end

    # Repeat the location and admission checks made when the repository
    # was opened. Raises when the Git directory has moved or been replaced,
    # or its ownership no longer passes.
    def revalidate! : Nil
      @metadata.check!
      raise Error.new("Git metadata changed during inspection") unless @metadata.common == @common && @metadata.git_dir == @git_dir
    end

    protected def check! : Nil
      revalidate!
    end

    getter object_format : ObjectId::Format

    def bare? : Bool
      @metadata.bare
    end

    def work_tree : String?
      @metadata.work_tree
    end

    private def require_worktree! : Nil
      raise Error.new("Git bare repository has no working tree") if bare?
    end

    # Repository config is interpreted from explicitly selected scopes only.
    # No HOME/XDG/system environment is inherited by this native library.
    # The host must decide which system/global files and command overrides are
    # authoritative; safe.directory and other protected settings are not a
    # grant to access arbitrary repository metadata.
    def config(*, system_files : Array(String) = [] of String,
               global_files : Array(String) = [] of String,
               command_values : Array({String, String?}) = [] of {String, String?},
               home : String? = nil,
               max_bytes : Int32 = 8_388_608,
               max_entries : Int32 = 100_000) : Config
      check!
      sources = [] of Config::Source
      system_files.each { |path| sources << Config::Source.new(Config::Scope::System, path) }
      global_files.each { |path| sources << Config::Source.new(Config::Scope::Global, path) }
      sources << Config::Source.new(Config::Scope::Local, File.join(@common, "config"))
      head_ref = @metadata.head[0]
      branch = head_ref.try do |ref|
        ref.starts_with?("refs/heads/") ? ref.byte_slice(11, ref.bytesize - 11) : nil
      end
      context = Config::Context.new(git_dir: @git_dir, work_tree: work_tree,
        branch: branch, home: home)
      # config.worktree is only active when explicitly enabled by the common
      # repository's extensions.worktreeConfig setting.
      local = Config.load(sources, context: context, max_bytes: max_bytes,
        max_entries: max_entries)
      extension = local.entries.reverse_each.find do |entry|
        entry.scope == Config::Scope::Local && entry.name == "extensions.worktreeconfig"
      end.try(&.value)
      if extension && {"true", "yes", "on", "1"}.includes?(extension.downcase)
        sources << Config::Source.new(Config::Scope::Worktree, File.join(@git_dir, "config.worktree"))
      end
      Config.load(sources, context: context, max_bytes: max_bytes,
        max_entries: max_entries, commands: command_values)
    end

    # Git-compatible dubious-owner check using only host-selected protected
    # config sources. Local/worktree safe.directory entries are never loaded
    # as authorization, and no ambient UID/SUDO_UID/HOME is implicitly read.
    # Call this before using untrusted repository contents. For a checked
    # constructor, use Repository.open_with_ownership_check instead of Repository.new.
    def safe_directory?(identity : Admission::Identity, *,
                        system_files : Array(String) = [] of String,
                        global_files : Array(String) = [] of String,
                        command_values : Array({String, String?}) = [] of {String, String?},
                        home : String? = nil, git_prefix : String? = nil) : Bool
      check!
      sources = [] of Config::Source
      system_files.each { |path| sources << Config::Source.new(Config::Scope::System, path) }
      global_files.each { |path| sources << Config::Source.new(Config::Scope::Global, path) }
      # Git evaluates safe.directory before establishing repository-specific
      # conditional include context. Protected unconditional includes still
      # resolve ~/ through the host-provided home directory.
      protected_config = Config.load(sources, context: Config::Context.new(home: home),
        commands: command_values)
      marker = File.join(@root, ".git")
      gitfile = !bare? && File.file?(marker) ? marker : nil
      allowed = Admission.allowed?(@root, @git_dir, bare?, gitfile, identity,
        protected_config, home: home, git_prefix: git_prefix)
      check!
      allowed
    end

    def require_safe_directory!(identity : Admission::Identity, **options) : Nil
      raise Error.new("unsafe Git repository ownership") unless safe_directory?(identity, **options)
    end

    # Git 2.x defaults to allowing implicit bare repository selection. This
    # explicitly protected-config-aware factory honors safe.bareRepository,
    # without importing ambient process config or restricting Repository.new's
    # low-level, unchecked semantics. A host-selected git_dir: remains an
    # explicit selection, while a work_tree: alone does not.
    def self.open_with_bare_repository_check(root : String, *,
                                             system_files : Array(String) = [] of String,
                                             global_files : Array(String) = [] of String,
                                             command_values : Array({String, String?}) = [] of {String, String?},
                                             home : String? = nil,
                                             **store_options) : Repository
      bare_admission = -> do
        protected_config = load_protected_config(system_files, global_files, command_values, home)
        Admission.require_implicit_bare_allowed!(protected_config)
      end
      new(root, **store_options.merge({before_implicit_bare: bare_admission}))
    end

    # An explicitly checked construction path. The older Repository.new remains a
    # low-level, unchecked reader for callers that enforce their own policy.
    def self.open_with_ownership_check(root : String, *,
                                       identity : Admission::Identity,
                                       system_files : Array(String) = [] of String,
                                       global_files : Array(String) = [] of String,
                                       command_values : Array({String, String?}) = [] of {String, String?},
                                       home : String? = nil, git_prefix : String? = nil,
                                       **store_options) : Repository
      # Location invokes this before consulting core.bare, core.worktree,
      # repository extensions or the object-format declaration. Only trusted
      # system/global/command inputs can authorize foreign ownership.
      admission = ->(site : Admission::Site) do
        protected_config = load_protected_config(system_files, global_files, command_values, home)
        unless Admission.allowed?(site.root, site.git_dir, site.bare, site.gitfile,
                 identity, protected_config, home: home, git_prefix: git_prefix)
          raise Error.new("unsafe Git repository ownership")
        end
      end
      bare_admission = -> do
        protected_config = load_protected_config(system_files, global_files, command_values, home)
        Admission.require_implicit_bare_allowed!(protected_config)
      end
      selected = new(root, **store_options.merge({before_config: admission, before_implicit_bare: bare_admission}))
      selected.require_safe_directory!(identity, system_files: system_files,
        global_files: global_files, command_values: command_values,
        home: home, git_prefix: git_prefix)
      selected
    end

    private def self.load_protected_config(system_files : Array(String), global_files : Array(String),
                                           commands : Array({String, String?}), home : String?) : Config
      sources = [] of Config::Source
      system_files.each { |path| sources << Config::Source.new(Config::Scope::System, path) }
      global_files.each { |path| sources << Config::Source.new(Config::Scope::Global, path) }
      # Do not manufacture repository context for a policy decision made
      # before an implicitly discovered bare repository is admitted.
      Config.load(sources, context: Config::Context.new(home: home), commands: commands)
    end

    # HEAD as a ref: symbolic (symref_target is the branch, oid nil while
    # it is unborn) or detached.
    def head : References::Ref
      @metadata.head_ref
    end

    # HEAD's symbolic target and object ID, for internal compare-and-swap
    # checks.
    protected def head_ref_and_oid : {String?, String?}
      @metadata.head
    end

    protected def resolve_ref?(ref : String, depth : Int32 = 0) : String?
      @metadata.resolve_ref?(ref, depth)
    end

    # Read and parse a commit object.
    def read_commit(oid : String, *, max_bytes : Int32 = 8_388_608,
                    check : Proc(Nil)? = nil) : Commit
      Commit.read(@object_database, oid, @object_format, max_bytes) { check.try &.call }
    end

    # Native, explicitly requested SHA-1/SHA-256 loose-blob publication.
    # Optional callbacks support ordinary Crystal integration (e.g. cancellation)
    # at defined pre-write, pre-publish and post-publish checkpoints. A failing
    # post-publish callback can leave a valid, unreferenced Git object.
    # The adapter's tools do not expose this mutating API by default.
    def write_blob(data : String | Bytes, *, max_bytes : Int64 = Int64::MAX,
                   check : Proc(Nil)? = nil) : String
      @object_database.write_blob(data, max_bytes: max_bytes) do
        check!
        check.try &.call
      end
    end

    # P17 native tree writer. Entries are byte-exact and structurally
    # validated, sorted and encoded by the standalone Git::Tree module.
    # Referenced objects may be missing, matching git mktree --missing.
    # check: observes pre-serialization and object-publication checkpoints;
    # a post-publication failure can leave a valid, unreferenced tree.
    def write_tree(entries : Enumerable(Tree::Entry), *,
                   max_bytes : Int64 = Int64::MAX,
                   max_entries : Int32 = Int32::MAX,
                   check : Proc(Nil)? = nil) : String
      check!
      check.try &.call
      raw = Tree.encode(entries, @object_format, max_bytes: max_bytes,
        max_entries: max_entries)
      @object_database.write_tree(raw, max_bytes: max_bytes) do
        check!
        check.try &.call
      end
    end

    # Publish a typed commit object, without updating a ref, index or HEAD.
    # Inputs are explicit; no ambient Git identity, hooks or process are used.
    def write_commit(*, tree : String, parents : Enumerable(String) = [] of String,
                     author : Signature, committer : Signature, message : String,
                     extra_headers : Enumerable(Commit::Header) = [] of Commit::Header,
                     max_bytes : Int64 = Int64::MAX,
                     max_parents : Int32 = Int32::MAX,
                     max_headers : Int32 = Int32::MAX,
                     check : Proc(Nil)? = nil) : String
      check!
      check.try &.call
      raw = Commit.encode(tree: tree, parents: parents, author: author,
        committer: committer, message: message, extra_headers: extra_headers,
        format: @object_format, max_bytes: max_bytes,
        max_parents: max_parents, max_headers: max_headers)
      @object_database.write_commit(raw, max_bytes: max_bytes) do
        check!
        check.try &.call
      end
    end

    # Publish the annotated tag object only. Updating refs/tags/* remains a
    # separately authorized future reference transaction.
    def write_tag(*, object : String, type : ObjectType, name : String,
                  message : String, tagger : Signature? = nil,
                  max_bytes : Int64 = Int64::MAX,
                  check : Proc(Nil)? = nil) : String
      check!
      check.try &.call
      raw = Tag.encode(object: object, type: type, name: name, tagger: tagger,
        message: message, format: @object_format, max_bytes: max_bytes)
      @object_database.write_tag(raw, max_bytes: max_bytes) do
        check!
        check.try &.call
      end
    end

    protected def object(oid : String, max_bytes : Int32, &check : -> Nil) : {String, String}
      @object_database.object(oid, max_bytes) { check.call }
    end

    # A stored object's type and contents (`git cat-file`).
    def read_object(oid : String, *, max_bytes : Int32 = 8_388_608,
                    check : Proc(Nil)? = nil) : RawObject
      type, data = @object_database.object(oid, max_bytes) { check.try &.call }
      RawObject.new(ObjectType.parse(type), data)
    end

    # Whether this repository has the object, loose or packed, without
    # reading it.
    def has_object?(oid : String) : Bool
      @object_database.has_object?(oid)
    end

    # Type and size from the stored header, without reading the contents
    # (`git cat-file -t/-s`). Not verified against the object ID.
    def object_header(oid : String, *, check : Proc(Nil)? = nil) : ObjectHeader
      type, size = @object_database.object_header(oid) { check.try &.call }
      ObjectHeader.new(ObjectType.parse(type), size)
    end

    # The pack directory reader (for copying stored entries).
    protected def pack_files : ObjectDatabase::PackFiles
      @object_database.pack_files
    end

    # Every loose and packed object ID once.
    def each_object_id(& : String ->) : Nil
      @object_database.each_oid { |oid| yield oid }
    end

    # The common Git directory (objects, refs, config).
    def common_dir : String
      @common
    end

    # The Git directory of this worktree (HEAD, index).
    def git_dir : String
      @git_dir
    end

    # The commits listed in .git/shallow (history cut by a shallow fetch).
    def shallow_commits : Set(String)
      path = File.join(@common, "shallow")
      return Set(String).new unless File.file?(path)
      File.read(path).lines.reject(&.empty?).map { |line| ObjectId.valid!(line.strip, @object_format) }.to_set
    end

    def shallow? : Bool
      !shallow_commits.empty?
    end

    # The staging area's entries, every stage, in index order
    # (`git ls-files --stage`).
    def index_entries(*, max_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Array(Index::Entry)
      @index.entries(max_bytes) { check.try &.call }
    end

    # Object IDs (loose or packed) that start with a lowercase hex prefix,
    # up to limit of them, sorted: what an abbreviated ID may mean.
    protected def object_ids_with_prefix(prefix : String, *, limit : Int32 = 16) : Array(String)
      @object_database.prefix_matches(prefix, limit)
    end

    # The committed entry at path in HEAD's tree (`git ls-tree HEAD path`).
    def head_entry(path : String, *, max_bytes : Int32 = 8_388_608,
                   check : Proc(Nil)? = nil) : Tree::Entry
      mode, oid = @head_tree.head_entry(path, max_bytes) { check.try &.call }
      Tree::Entry.new(path.split('/').last, mode, oid)
    end

    # The entries of a directory in HEAD's tree ("." for the root).
    def head_directory(path : String = ".", *, max_bytes : Int32 = 8_388_608,
                       check : Proc(Nil)? = nil) : Array(Tree::Entry)
      @head_tree.head_directory(path, max_bytes) { check.try &.call }.map do |name, mode, oid|
        Tree::Entry.new(name, mode, oid)
      end
    end

    # The committed text of a regular file in HEAD. Refuses a non-file or
    # content that is not UTF-8 text.
    def read_head_file(path : String, *, max_bytes : Int32 = 8_388_608,
                       check : Proc(Nil)? = nil) : String
      @head_tree.read_head_file(path, max_bytes) { check.try &.call }[1]
    end

    private def parse_tree(raw : String) : Array({String, String, String})
      @head_tree.parse_tree(raw)
    end
  end
end
