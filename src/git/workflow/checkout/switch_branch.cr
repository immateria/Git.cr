module Git
  class Repository
    # `git switch <branch>`: check out a local branch (or `"-"` for the
    # previously checked-out branch/commit). With create (`-c`) target names
    # a new branch started at from (default HEAD); with force_create (`-C`) an
    # existing branch is reset to from; with detach (`--detach`) target is any
    # commit and HEAD is left detached there. Otherwise a missing branch that
    # exactly one remote has is created from that remote-tracking branch, as
    # Git guesses (guess: false turns this off). A created or force-created
    # branch gets an upstream as Branches#create gives one unless track is
    # false. With actor, HEAD's reflog gets Git's
    # "checkout: moving from <old> to <target>" and a created/reset branch's
    # reflog "branch: Created from <start>" or "branch: Reset to <start>".
    #
    # The repository must be clean and ordinary: regular files, staged state
    # equal to HEAD, unchanged tracked files. File/directory transitions are
    # planned explicitly and refuse untracked content before publication.
    # Worktree, index, a created branch and HEAD are published in that
    # order, not atomically.
    def switch(target : String, *, create : Bool = false, force_create : Bool = false,
               from : String? = nil, detach : Bool = false, guess : Bool = true,
               track : Bool = true, actor : Signature? = nil,
               max_blob_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864,
               max_files : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Checkout::Result
      require_worktree!
      creating = create || force_create
      raise ArgumentError.new("Git switch cannot both create and detach") if creating && detach
      raise ArgumentError.new("Git switch from: needs create") if from && !creating
      raise Error.new("Git checkout refuses in-progress merge") if merge_state?
      raise Error.new("Git checkout refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git checkout refuses in-progress rebase") if rebase_state?
      raise ArgumentError.new("invalid Git checkout budgets") if max_blob_bytes < 128 || max_index_bytes < 128 ||
                                                                 max_total_bytes < max_blob_bytes || max_files < 1 || max_files > @max_search_entries
      check!
      raise Error.new("Git checkout unsupported with linked worktrees") unless @git_dir == @common &&
                                                                               (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      if target == "-" && !creating
        prior = Revision::Parser.new(self, max_blob_bytes).prior_checkout(1)
        if !detach && prior.bytesize == @object_format.hexsize && prior.each_char.all?(&.hex?) &&
           resolve_ref?("refs/heads/#{prior}").nil?
          detach = true
        end
        target = prior
      end
      original_ref, original_oid = head_ref_and_oid
      # What HEAD will name (nil when detached), a branch to create/reset there,
      # its expected old OID and the start point it is created/reset from.
      head_ref = nil.as(String?)
      new_branch = nil.as(String?)
      expected_branch_oid = nil.as(String?)
      start = "HEAD"
      upstream = nil.as({String, String}?)
      if detach
        target_oid = History.resolve_commit(self, target, max_blob_bytes, check)
      else
        branch_ref = new_branch_ref(target)
        head_ref = branch_ref
        existing = resolve_ref?(branch_ref)
        if creating
          raise Error.new("Git branch #{target} already exists") if existing && !force_create
          start = from || "HEAD"
          new_branch = branch_ref
          expected_branch_oid = existing
        elsif existing.nil?
          start = (guess ? guess_remote_branch(target) : nil) || raise Error.new("Git checkout branch missing")
          new_branch = branch_ref
        end
        target_oid = History.resolve_commit(self, new_branch ? start : branch_ref, max_blob_bytes, check)
        if new_branch
          upstream = start_point_upstream(target, start) if track
        elsif target_oid != existing
          raise Error.new("Git checkout branch does not resolve to a direct commit")
        end
      end
      checkout_log = actor.try do |who|
        old_name = original_ref.try { |ref| ref.starts_with?("refs/heads/") ? ref.byte_slice(11) : ref } || original_oid
        References::LogEntry.new(who, "checkout: moving from #{old_name} to #{target}")
      end
      if new_branch.nil? && head_ref && original_ref == head_ref
        checkout_log.try { |entry| append_head_log(original_oid, target_oid, entry) }
        return Checkout::Result.new(head_ref, target_oid, [] of String)
      end
      target_unchanged = -> do
        if branch = new_branch
          resolve_ref?(branch) == expected_branch_oid
        elsif reference = head_ref
          resolve_ref?(reference) == target_oid
        else
          true
        end
      end
      old_tree = original_oid ? read_commit(original_oid, max_bytes: max_blob_bytes, check: check).tree : nil
      next_tree = read_commit(target_oid, max_bytes: max_blob_bytes, check: check).tree
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git checkout index entry budget exceeded") if current.size > max_files
      original = old_tree ? Checkout.tree_files(self, old_tree, max_object_bytes: max_blob_bytes, max_files: max_files, check: check) : {} of String => Checkout::FileState
      desired = Checkout.tree_files(self, next_tree, max_object_bytes: max_blob_bytes, max_files: max_files, check: check)
      raise Error.new("Git checkout requires index equal to HEAD") unless current.size == original.size && current.all? do |entry|
                                                                            entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                            original[entry.path]?.try { |value| value.mode == entry.mode && value.oid == entry.oid } == true
                                                                          end
      Checkout.require_tree_paths!(original.keys, "Git checkout predecessor")
      Checkout.require_tree_paths!(desired.keys, "Git checkout destination")
      Checkout.require_clean!(self, current, max_blob_bytes: max_blob_bytes,
        max_total_bytes: max_total_bytes, check: check)
      Checkout.require_transition_destinations!(@root, original.keys, desired.keys,
        max_entries: max_files)
      changed = (original.keys + desired.keys).uniq.sort.select { |path| original[path]? != desired[path]? }
      raise Error.new("Git checkout entry budget exceeded") if changed.size > max_files
      edits = [] of Index::Edit
      writes = [] of Checkout::Write
      removes = [] of String
      transferred = 0_i64
      changed.each do |path|
        check.try &.call
        if next_entry = desired[path]?
          kind, raw = @object_database.object(next_entry.oid, max_blob_bytes) { check.try &.call }
          raise Error.new("Git checkout entry is not a blob") unless kind == "blob"
          transferred += raw.bytesize
          raise Error.new("Git checkout total byte budget exceeded") if transferred > max_total_bytes
          writes << Checkout::Write.new(path, next_entry.mode, next_entry.oid, raw)
          edits << Index::Put.new(path, next_entry.mode, next_entry.oid)
        else
          removes << path
          edits << Index::Remove.new(path)
        end
      end
      image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
        max_entries: max_files, check: check)
      write_paths = writes.map(&.path)
      blocking_removes, trailing_removes = removes.partition do |path|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = Checkout.transition_directories(original.keys, desired.keys)
      original_checksum = @index.snapshot_checksum(max_index_bytes)
      raise Error.new("Git checkout index changed during planning") if image &&
                                                                       @index.image_state(image, max_bytes: max_index_bytes) != :before
      admin = DescriptorPath::Directory.open(@git_dir)
      index_lock = nil.as(IO::FileDescriptor?)
      head_lock = nil.as(IO::FileDescriptor?)
      changed_paths = [] of String
      index_published = false
      publication_started = false
      begin
        index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        head_lock = admin.open_file("HEAD.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        head_original_io = admin.open_file("HEAD", LibC::O_RDONLY)
        head_original = begin
          head_original_io.gets_to_end
        ensure
          head_original_io.close
        end
        raise Error.new("Git checkout HEAD changed before publication") unless head_ref_and_oid == {original_ref, original_oid}
        raise Error.new("Git checkout index changed before publication") unless @index.snapshot_checksum(max_index_bytes) == original_checksum
        raise Error.new("Git checkout target branch changed") unless target_unchanged.call
        Checkout.require_clean!(self, current, max_blob_bytes: max_blob_bytes,
          max_total_bytes: max_total_bytes, check: check)
        Checkout.require_transition_destinations!(@root, original.keys, desired.keys,
          max_entries: max_files)
        blocking_removes.each do |path|
          publication_started = true
          Checkout.remove(@root, path, original[path], format: @object_format, check: check)
          changed_paths << path
        end
        transition_dirs.each do |directory|
          publication_started = true
          Checkout.remove_empty_directory(@root, directory, check: check)
        end
        writes.each_with_index do |write, sequence|
          publication_started = true
          Checkout.write(@root, write, sequence, expected_old: original[write.path]?,
            format: @object_format, check: check)
          changed_paths << write.path
        end
        trailing_removes.each do |path|
          publication_started = true
          Checkout.remove(@root, path, original[path], format: @object_format, check: check)
          changed_paths << path
        end
        check.try &.call
        raise Error.new("Git checkout HEAD or branch changed") unless head_ref_and_oid == {original_ref, original_oid} && target_unchanged.call
        raise Error.new("Git checkout index changed") unless @index.snapshot_checksum(max_index_bytes) == original_checksum
        if selected = image
          raise Error.new("Git checkout index image diverged") unless @index.image_state(selected, max_bytes: max_index_bytes) == :before
          index_lock.not_nil!.write(selected.data.to_slice)
          index_lock.not_nil!.flush
          index_lock.not_nil!.fsync
          raise Error.new("Git checkout admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
        if branch = new_branch
          publication_started = true
          branch_log = actor.try do |who|
            action = expected_branch_oid ? "Reset to" : "Created from"
            References::LogEntry.new(who, "branch: #{action} #{start}")
          end
          if expected_branch_oid && target_oid == expected_branch_oid
            if entry = branch_log
              References::Transaction.append_log(@common, branch, entry.encode(expected_branch_oid, target_oid))
            end
          else
            update_ref(branch, target_oid, expected_oid: expected_branch_oid, log: branch_log, max_object_bytes: max_blob_bytes)
          end
          upstream.try { |remote_name, merge_ref| set_branch_upstream(target, remote_name, merge_ref) }
        end
        head_lock.not_nil!.write((head_ref ? "ref: #{head_ref}\n" : "#{target_oid}\n").to_slice)
        head_lock.not_nil!.flush
        head_lock.not_nil!.fsync
        readback = admin.open_file("HEAD", LibC::O_RDONLY)
        head_current = begin
          readback.gets_to_end
        ensure
          readback.close
        end
        raise Error.new("Git checkout HEAD changed") unless head_current == head_original || (original_ref == head_ref && head_ref != nil)
        raise Error.new("Git checkout admin directory replaced") unless admin.attached_at?(@git_dir)
        admin.rename("HEAD.lock", "HEAD")
        admin.sync
        # When resetting an existing branch that wasn't currently checked out,
        # update_ref only appended to the branch log; append the checkout line
        # to HEAD's log unless update_ref already appended the Reset line to HEAD.
        if !(new_branch && original_ref == new_branch && target_oid != expected_branch_oid)
          checkout_log.try { |entry| append_head_log(original_oid, target_oid, entry) }
        elsif entry = checkout_log
          append_head_log(target_oid, target_oid, entry)
        end
        Checkout::Result.new(head_ref, target_oid, changed_paths)
      rescue ex
        if publication_started || index_published
          raise Checkout::PartialPublication.new(changed_paths.dup, index_published, ex)
        end
        raise ex
      ensure
        if io = head_lock
          if admin.same_inode?("HEAD.lock", io)
            admin.unlink("HEAD.lock")
            admin.sync
          end
          io.close unless io.closed?
        end
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

    # Git's checkout guess: the remote-tracking branch for name when exactly
    # one remote has it, or checkout.defaultRemote's when several do.
    private def guess_remote_branch(name : String) : String?
      found = [] of {String, String}
      remote_names.each do |remote_name|
        tracking = remote?(remote_name).try(&.tracking_ref("refs/heads/#{name}"))
        found << {remote_name, tracking} if tracking && resolve_ref?(tracking)
      end
      return found.first[1] if found.size == 1
      return nil if found.empty?
      preferred = local_config.value?("checkout.defaultRemote")
      found.each { |remote_name, tracking| return tracking if remote_name == preferred }
      raise Error.new("Git branch #{name} matches more than one remote-tracking branch")
    end
  end
end
