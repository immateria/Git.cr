module Git
  class Repository
    # Save the index/worktree state and push it onto refs/stash. The default
    # tracked-only form uses Git's standard two-parent stash shape. With
    # include_untracked, a parentless third commit stores non-ignored untracked
    # files exactly as Git stash -u does. include_ignored widens that third
    # snapshot to all untracked leaves like Git stash -a and implies untracked
    # capture. keep_index preserves the caller's staged index. staged_only
    # stores only the index delta and removes that staged delta from the
    # worktree while preserving bounded non-overlapping unstaged edits. paths
    # selects exact repository-relative file paths without Git pathspec/glob
    # expansion; the stash object still retains Git's full saved-index parent.
    # The caller supplies identity/time explicitly; no ambient Git config,
    # environment or clock is consulted.
    def stash_push(*, actor : Signature, message : String? = nil,
                   include_untracked : Bool = false,
                   include_ignored : Bool = false,
                   keep_index : Bool = false,
                   staged_only : Bool = false,
                   paths : Array(String)? = nil,
                   max_object_bytes : Int32 = 8_388_608,
                   max_index_bytes : Int32 = 8_388_608,
                   max_total_bytes : Int64 = 67_108_864,
                   max_entries : Int32 = 10_000,
                   max_log_bytes : Int32 = 8_388_608,
                   check : Proc(Nil)? = nil) : Stash::Entry?
      require_worktree!
      raise ArgumentError.new("invalid Git stash budgets") if max_object_bytes < 128 || max_index_bytes < 128 ||
                                                              max_total_bytes < max_object_bytes || max_entries < 1 ||
                                                              max_entries > @max_search_entries || max_log_bytes < 128
      selected_paths = if selected = paths
                         raise Error.new("empty Git stash selected paths") if selected.empty? || selected.size > max_entries
                         chosen = Set(String).new
                         selected.each do |path|
                           PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
                           raise Error.new("Git stash selected path targets repository metadata") if path == ".git" || path.starts_with?(".git/")
                           raise Error.new("duplicate Git stash selected path") unless chosen.add?(path)
                         end
                         chosen
                       end
      if staged_only && (include_untracked || include_ignored)
        raise ArgumentError.new("staged-only Git stash cannot capture untracked or ignored files")
      end
      raise ArgumentError.new("staged-only Git stash does not support selected paths") if staged_only && selected_paths
      check!
      raise Error.new("Git stash unsupported with linked worktrees") unless @git_dir == @common &&
                                                                            (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      raise Error.new("Git stash refuses in-progress merge") if merge_state?
      raise Error.new("Git stash refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git stash refuses in-progress rebase") if rebase_state?
      if text = message
        raise Error.new("Git stash message invalid") if text.empty? || text.includes?('\0') || text.includes?('\n') || text.includes?('\r') || text.bytesize > 4096
      end

      branch, head_oid = head
      raise Error.new("Git stash requires an existing symbolic branch") unless branch && branch.starts_with?("refs/heads/") && head_oid
      head_commit = commit(head_oid, max_object_bytes) { check.try &.call }
      head_files = Checkout.tree_files(self, head_commit.tree,
        max_object_bytes: max_object_bytes, max_files: max_entries,
        check: check, allow_symlinks: true)
      current = @index.entries(max_index_bytes) { check.try &.call }
      raise Error.new("Git stash index entry budget exceeded") if current.size > max_entries
      current.each do |entry|
        raise Error.new("Git stash requires an ordinary resolved index") unless entry.stage == 0 && !entry.intent &&
                                                                                !entry.skip_worktree && !entry.assume_unchanged &&
                                                                                {"100644", "100755", "120000"}.includes?(entry.mode)
      end
      Checkout.require_tree_paths!(current.map(&.path), "Git stash index")
      index_tree = write_index_tree(max_index_bytes: max_index_bytes,
        max_tree_bytes: max_object_bytes, check: check)
      index_files = {} of String => Checkout::FileState
      current.each do |entry|
        index_files[entry.path] = Checkout::FileState.new(entry.mode, entry.oid)
      end

      # Git partial stash stores a complete index-shaped worktree tree and
      # overlays only the selected paths with their actual worktree state.
      # This intentionally means unselected staged changes remain represented
      # in the stash object even though cleanup is limited to selected paths.
      worktree_files = selected_paths ? index_files.dup : ({} of String => Checkout::FileState)
      observed = {} of String => Checkout::FileState
      index_paths = current.map(&.path).to_set
      transferred = 0_i64
      current.each do |entry|
        next if selected_paths && !selected_paths.includes?(entry.path)
        check.try &.call
        if leaf = stash_worktree_leaf?(entry.path, max_object_bytes,
             allow_directory_missing: false, check: check)
          state, raw = leaf
          transferred += raw.bytesize
          raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
          written = write_blob(raw, max_bytes: max_object_bytes.to_i64, check: check)
          raise Error.new("Git stash worktree blob identity changed") unless written == state.oid
          worktree_files[entry.path] = state
          observed[entry.path] = state
        elsif selected_paths
          worktree_files.delete(entry.path)
        end
      end

      untracked_files = {} of String => Checkout::FileState
      capture_untracked = include_untracked || include_ignored
      if capture_untracked
        untracked_files, untracked_bytes = stash_untracked_files(index_paths,
          selected_paths: selected_paths,
          include_ignored: include_ignored,
          max_object_bytes: max_object_bytes,
          max_total_bytes: max_total_bytes - transferred,
          max_entries: max_entries,
          check: check)
        transferred += untracked_bytes
        untracked_files.each do |path, state|
          observed[path] = state
          # A staged deletion makes a formerly tracked HEAD path untracked.
          # Git's -u stash records that leaf in both the worktree snapshot and
          # the third-parent untracked snapshot, so applying it later may
          # legitimately encounter the same collision Git does.
          worktree_files[path] = state if head_files.has_key?(path)
        end
      end

      # A path removed from the index is untracked from Git's point of view.
      # If it still occupies a HEAD path and was not captured by -u, preserve
      # safety by accepting it only when it is byte-for-byte the original HEAD
      # value. Git itself may overwrite a modified such path during cleanup;
      # this native lane intentionally refuses that data-loss case unless the
      # bytes are durably represented in the third-parent snapshot.
      head_files.each do |path, expected|
        next if selected_paths && !selected_paths.includes?(path)
        next if index_paths.includes?(path)
        next if untracked_files.has_key?(path)
        leaf = stash_worktree_leaf?(path, max_object_bytes,
          allow_directory_missing: true, check: check)
        next unless leaf
        actual, raw = leaf
        transferred += raw.bytesize
        raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
        raise Error.new("Git stash refuses modified worktree content excluded by staged deletion") unless actual == expected
        observed[path] = actual
      end

      if selected_paths
        selected_paths.each do |path|
          next if index_paths.includes?(path) || untracked_files.has_key?(path)
          raise Error.new("Git stash selected path did not match an indexed or captured worktree file: #{path}")
        end
      end

      worktree_tree = staged_only ? index_tree : stash_write_tree(worktree_files,
        max_object_bytes: max_object_bytes, check: check)
      if staged_only
        return nil if index_tree == head_commit.tree
      elsif selected_paths
        selected_changed = selected_paths.any? do |path|
          index_files[path]? != head_files[path]? ||
            worktree_files[path]? != index_files[path]? ||
            untracked_files.has_key?(path)
        end
        return nil unless selected_changed
      elsif index_tree == head_commit.tree && worktree_tree == head_commit.tree && untracked_files.empty?
        return nil
      end

      image = if keep_index
                nil
              else
                desired_index = IndexRestore.source_entries(self, head_commit.tree,
                  max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
                index_selection = selected_paths.try do |selected|
                  selected.select { |path| index_paths.includes?(path) || head_files.has_key?(path) }.to_set
                end
                edits = IndexRestore.edits(current, desired_index, index_selection)
                edits.empty? ? nil : @index.prepare_changes(edits,
                  max_bytes: max_index_bytes, max_entries: max_entries, check: check)
              end
      checksum = @index.snapshot_checksum(max_index_bytes)
      cleanup_files = if staged_only
                        staged_cleanup, merged_bytes = stash_staged_cleanup_files(head_files, index_files, observed,
                          max_object_bytes: max_object_bytes,
                          max_total_bytes: max_total_bytes - transferred,
                          check: check)
                        transferred += merged_bytes
                        staged_cleanup
                      elsif selected_paths
                        source = keep_index ? index_files : head_files
                        selected_cleanup = {} of String => Checkout::FileState
                        selected_paths.each do |path|
                          if state = source[path]?
                            selected_cleanup[path] = state
                          end
                        end
                        selected_cleanup
                      elsif keep_index
                        index_files
                      else
                        head_files
                      end

      Checkout.require_tree_paths!(observed.keys, "Git stash worktree")
      Checkout.require_tree_paths!(cleanup_files.keys, "Git stash cleanup destination")
      Checkout.require_transition_destinations!(@root, observed.keys, cleanup_files.keys,
        max_entries: max_entries)
      changed = (observed.keys + cleanup_files.keys).uniq.sort.select { |path| observed[path]? != cleanup_files[path]? }
      raise Error.new("Git stash cleanup entry budget exceeded") if changed.size > max_entries
      writes = [] of Checkout::Write
      removals = [] of String
      changed.each do |path|
        check.try &.call
        if goal = cleanup_files[path]?
          kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
          raise Error.new("Git stash cleanup target is not a blob") unless kind == "blob"
          transferred += raw.bytesize
          raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
          writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
        elsif observed.has_key?(path)
          removals << path
        end
      end
      write_paths = writes.map(&.path)
      blocking_removals, trailing_removals = removals.partition do |path|
        write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
      end
      transition_dirs = Checkout.transition_directories(observed.keys, cleanup_files.keys)

      # Validate the existing stack before appending another Git-compatible
      # reflog entry. Malformed or mismatched external state is never extended.
      stash_log_records(max_log_bytes: max_log_bytes, max_entries: max_entries,
        max_object_bytes: max_object_bytes, check: check)
      previous_stash = resolve_ref?(Stash::REF)
      branch_name = branch.byte_slice("refs/heads/".bytesize, branch.bytesize - "refs/heads/".bytesize)
      short = head_oid.byte_slice(0, {7, head_oid.bytesize}.min)
      description = message ? "On #{branch_name}: #{message}" : "WIP on #{branch_name}: #{short} #{head_commit.subject}"
      index_commit = write_commit(tree: index_tree, parents: [head_oid], author: actor,
        committer: actor, message: "index on #{branch_name}: #{short} #{head_commit.subject}\n",
        max_bytes: max_object_bytes.to_i64, check: check)
      untracked_commit = nil.as(String?)
      if capture_untracked
        untracked_tree = stash_write_tree(untracked_files,
          max_object_bytes: max_object_bytes, check: check)
        untracked_commit = write_commit(tree: untracked_tree, author: actor,
          committer: actor,
          message: "untracked files on #{branch_name}: #{short} #{head_commit.subject}\n",
          max_bytes: max_object_bytes.to_i64, check: check)
      end
      parents = [head_oid, index_commit]
      parents << untracked_commit.not_nil! if untracked_commit
      stash_oid = write_commit(tree: worktree_tree, parents: parents,
        author: actor, committer: actor, message: description,
        max_bytes: max_object_bytes.to_i64, check: check)

      guard = -> do
        check.try &.call
        raise Error.new("Git stash HEAD changed") unless head == {branch, head_oid}
        raise Error.new("Git stash index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
      end

      admin = DescriptorPath::Directory.open(@git_dir)
      index_lock = nil.as(IO::FileDescriptor?)
      started = false
      ref_published = false
      index_published = false
      changed_paths = [] of String
      begin
        # Serialize cooperative index writers before publishing refs/stash so a
        # pre-existing foreign lock cannot turn an otherwise avoidable refusal
        # into a saved-but-not-cleaned partial operation.
        index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        guard.call
        stash_verify_worktree_snapshot!(current, worktree_files, observed,
          selected_paths: selected_paths,
          max_object_bytes: max_object_bytes, check: check)
        Checkout.require_transition_destinations!(@root, observed.keys, cleanup_files.keys,
          max_entries: max_entries)
        if planned = image
          raise Error.new("Git stash cleanup index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          index_lock.write(planned.data.to_slice)
          index_lock.flush
          index_lock.fsync
        end

        update_ref(Stash::REF, stash_oid, expected_oid: previous_stash,
          log: References::LogEntry.new(actor, description),
          max_object_bytes: max_object_bytes, check: guard)
        ref_published = true

        blocking_removals.each do |path|
          started = true
          Checkout.remove(@root, path, observed[path], format: @object_format, check: guard)
          changed_paths << path
        end
        transition_dirs.each do |directory|
          started = true
          Checkout.remove_empty_directory(@root, directory, check: guard)
        end
        writes.each_with_index do |write, sequence|
          started = true
          Checkout.write(@root, write, sequence, expected_old: observed[write.path]?,
            format: @object_format, check: guard)
          changed_paths << write.path
        end
        trailing_removals.each do |path|
          started = true
          Checkout.remove(@root, path, observed[path], format: @object_format, check: guard)
          changed_paths << path
        end
        if planned = image
          guard.call
          raise Error.new("Git stash cleanup index image diverged after worktree publication") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
          raise Error.new("Git stash cleanup admin directory replaced") unless admin.attached_at?(@git_dir)
          admin.rename("index.lock", "index")
          index_published = true
          admin.sync
        end
      rescue ex
        if ref_published
          raise Stash::PartialSave.new(stash_oid, changed_paths.dup, index_published, ex)
        end
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

      Stash::Entry.new(0, stash_oid, head_oid, index_commit, worktree_tree,
        index_tree, description, untracked_commit)
    end
  end
end
