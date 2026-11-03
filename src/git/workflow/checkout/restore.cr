module Git
  class Repository
    # Accessors stay on Repository so Checkout need not reach into unrelated
    # store internals or bind this shard to a host.
    def checkout_tree_entries(raw : String) : Array({String, String, String})
      @head_tree.parse_tree(raw)
    end

    def checkout_working_regular(path : String, max_bytes : Int32, &check : -> Nil) : {String, String}
      @worktree.stage_content(path, max_bytes) { check.call }
    end

    # Restore explicitly named, currently indexed regular paths from a commit
    # to the worktree only. Deliberately overwrites dirty tracked bytes at those
    # paths; never touches the index or HEAD and never creates an untracked
    # path. For staged restoration use the separate index API in a later slice.
    def restore_paths(paths : Array(String), *, source : String = "HEAD",
                      max_blob_bytes : Int32 = 8_388_608,
                      max_index_bytes : Int32 = 8_388_608,
                      max_total_bytes : Int64 = 67_108_864,
                      max_files : Int32 = 10_000,
                      check : Proc(Nil)? = nil) : Array(String)
      require_worktree!
      raise ArgumentError.new("invalid Git restore budgets") if max_blob_bytes < 128 || max_index_bytes < 128 ||
                                                                max_total_bytes < max_blob_bytes || max_files < 1 || max_files > @max_search_entries
      raise Error.new("empty Git restore path set") if paths.empty? || paths.size > max_files
      raise Error.new("duplicate Git restore path") unless paths.uniq.size == paths.size
      paths.each { |path| PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH) }
      check!
      source_oid = History.resolve_commit(self, source, max_blob_bytes, check)
      source_tree = commit(source_oid, max_blob_bytes) { check.try &.call }.tree
      desired = Checkout.tree_files(self, source_tree, max_object_bytes: max_blob_bytes,
        max_files: max_files, check: check)
      entries = @index.entries(max_index_bytes) { check.try &.call }
      selected = {} of String => Index::Entry
      entries.each { |entry| selected[entry.path] = entry if paths.includes?(entry.path) }
      raise Error.new("Git restore requires tracked paths") unless selected.size == paths.size
      writes = [] of Checkout::Write
      removes = [] of {String, Checkout::FileState}
      observed = {} of String => Checkout::FileState?
      total = 0_i64
      paths.each do |path|
        check.try &.call
        indexed = selected[path]
        raise Error.new("Git restore requires regular resolved index paths") unless indexed.stage == 0 &&
                                                                                    !indexed.intent && !indexed.skip_worktree && {"100644", "100755"}.includes?(indexed.mode)
        absolute = File.join(@root, path)
        parent = @root
        missing_parent = false
        path.split('/')[0...-1].each do |component|
          parent = File.join(parent, component)
          raise Error.new("Git restore symlinked parent") if File.symlink?(parent)
          if File.exists?(parent)
            raise Error.new("Git restore blocked parent") unless Dir.exists?(parent) && File.realpath(parent) == parent
          else
            missing_parent = true
          end
        end
        raise Error.new("Git restore refuses symlinked tracked file") if File.symlink?(absolute)
        if !missing_parent && File.exists?(absolute)
          raise Error.new("Git restore tracked path is not regular") unless File.file?(absolute)
          current_mode, current_bytes = @worktree.stage_content(path, max_blob_bytes) { check.try &.call }
          total += current_bytes.bytesize
          raise Error.new("Git restore byte budget exceeded") if total > max_total_bytes
          current = Checkout::FileState.new(current_mode, ObjectId.digest("blob", current_bytes, @object_format))
        else
          current = nil.as(Checkout::FileState?)
        end
        observed[path] = current
        if desired_entry = desired[path]?
          next if desired_entry == current
          kind, bytes = @object_database.object(desired_entry.oid, max_blob_bytes) { check.try &.call }
          raise Error.new("Git restore target is not a blob") unless kind == "blob"
          total += bytes.bytesize
          raise Error.new("Git restore byte budget exceeded") if total > max_total_bytes
          writes << Checkout::Write.new(path, desired_entry.mode, desired_entry.oid, bytes)
        elsif old = current
          removes << {path, old}
        end
      end
      checksum = @index.snapshot_checksum(max_index_bytes)
      index_lock = nil.as(IO::FileDescriptor?)
      admin = DescriptorPath::Directory.open(@git_dir)
      changed = [] of String
      started = false
      begin
        index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        raise Error.new("Git restore index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
        raise Error.new("Git restore source changed") unless History.resolve_commit(self, source, max_blob_bytes, check) == source_oid
        writes.each_with_index do |write, sequence|
          started = true
          Checkout.write(@root, write, sequence, expected_old: observed[write.path],
            format: @object_format, check: check)
          changed << write.path
        end
        removes.each do |path, expected|
          started = true
          Checkout.remove(@root, path, expected, format: @object_format, check: check)
          changed << path
        end
        raise Error.new("Git restore index changed during publication") unless @index.snapshot_checksum(max_index_bytes) == checksum
        changed
      rescue ex
        raise Checkout::PartialPublication.new(changed.dup, false, ex) if started
        raise ex
      ensure
        if io = index_lock
          if admin.same_inode?("index.lock", io)
            admin.unlink("index.lock")
            admin.sync
          end
          io.close unless io.closed?
        end
        admin.close
      end
    end
  end
end
