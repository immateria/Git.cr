module Git
  class Repository
    # Rebase the current symbolic branch (or detached HEAD) onto `upstream`,
    # or onto an explicit alternate commit while still selecting commits
    # relative to `upstream`. The selected branch-only history must be a linear
    # first-parent chain. Clean items replay synchronously; conflicts leave
    # REBASE_HEAD plus the normal index stages and can be resumed with
    # rebase_continue/skip/abort.
    def rebase(upstream : String, *, committer : Signature,
               onto : String? = nil, keep_empty : Bool = false,
               max_commits : Int32 = 512, max_graph_nodes : Int32 = 16_384,
               max_object_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864,
               max_entries : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Rebase::Result
      require_worktree!
      raise ArgumentError.new("invalid Git rebase budgets") if max_commits < 0 || max_commits > 512 ||
                                                               max_graph_nodes < 1 || max_object_bytes < 128 ||
                                                               max_index_bytes < 128 || max_total_bytes < max_object_bytes ||
                                                               max_entries < 1 || max_entries > @max_search_entries
      check!
      raise Error.new("Git rebase unsupported with linked worktrees") unless @git_dir == @common &&
                                                                             (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
      raise Error.new("Git rebase refuses in-progress merge") if merge_state?
      raise Error.new("Git rebase refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git rebase already in progress") if rebase_state?
      branch, original_head = head_ref_and_oid
      unless original_head && (branch.nil? || branch.starts_with?("refs/heads/"))
        raise Error.new("Git rebase requires an existing branch or detached HEAD")
      end
      upstream_oid = History.resolve_commit(self, upstream, max_object_bytes, check)
      onto_oid = History.resolve_commit(self, onto || upstream, max_object_bytes, check)
      base, todo = rebase_plan(original_head, upstream_oid,
        max_commits: max_commits, max_graph_nodes: max_graph_nodes,
        max_object_bytes: max_object_bytes, check: check)

      rebase_preflight_clean!(original_head, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)

      # A branch already based directly on the requested upstream is already
      # up to date unless an explicit --onto-like destination was requested.
      if onto.nil? && base == upstream_oid
        return Rebase::Result.new(branch, original_head, onto_oid, original_head,
          0, 0, [] of String, true)
      end
      state = Rebase::State.new(branch, original_head, upstream_oid, onto_oid,
        todo, 0, onto_oid, keep_empty)
      rebase_write_initial_state!(state)
      write_orig_head(original_head)
      if original_head != onto_oid
        begin
          rebase_move_branch!(state, original_head, onto_oid,
            log: References::LogEntry.new(committer, "rebase (start): checkout #{onto || upstream}"),
            max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
            max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
        rescue ex : Rebase::PartialPublication
          raise ex
        rescue ex
          # No publication began: do not strand an otherwise untouched branch
          # in synthetic rebase state because, for example, a foreign index
          # lock prevented the base move from starting.
          if head_ref_and_oid == {branch, original_head} && rebase_state? == state && sequencer_state?.nil?
            rebase_clear_state!(state)
          end
          raise ex
        end
      end
      rebase_run(state, committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    # Durable outer rebase plan/progress. Per-item conflict state is exposed by
    # `sequencer_state?` and must have kind Rebase while a replay is stopped.
    protected def rebase_state? : Rebase::State?
      check!
      parent = DescriptorPath::Directory.open(@git_dir)
      child = nil.as(DescriptorPath::Directory?)
      begin
        return nil unless parent.stat?("rebase-merge")
        child = parent.open_directory("rebase-merge")
        raw_branch = rebase_read_file!(child, "head-name", 4_096).strip
        branch = if raw_branch == "detached HEAD"
                   nil
                 else
                   raise Error.new("Git rebase branch state invalid") unless raw_branch.starts_with?("refs/heads/") && RefName.valid?(raw_branch)
                   raw_branch
                 end
        original_head = ObjectId.valid!(rebase_read_file!(child, "orig-head", 256).strip, @object_format)
        upstream = ObjectId.valid!(rebase_read_file!(child, "upstream", 256).strip, @object_format)
        onto = ObjectId.valid!(rebase_read_file!(child, "onto", 256).strip, @object_format)
        todo_text = rebase_read_file!(child, "git-rebase-todo", 65_536)
        todo = todo_text.lines.map(&.strip).reject(&.empty?).map do |oid|
          ObjectId.valid!(oid, @object_format)
        end
        raise Error.new("Git rebase todo budget exceeded") if todo.size > 512
        dynamic = rebase_read_file!(child, "state", 4_096).lines.map(&.strip)
        raise Error.new("Git rebase dynamic state invalid") unless dynamic.size == 3 &&
                                                                   dynamic[0].starts_with?("next ") &&
                                                                   dynamic[1].starts_with?("expected ") &&
                                                                   dynamic[2].starts_with?("keep-empty ")
        next_index = dynamic[0].byte_slice(5).to_i?
        raise Error.new("Git rebase next index invalid") unless next_index && next_index >= 0 && next_index <= todo.size
        expected = ObjectId.valid!(dynamic[1].byte_slice(9), @object_format)
        keep_empty = case dynamic[2].byte_slice(11)
                     when "0" then false
                     when "1" then true
                     else          raise Error.new("Git rebase empty policy invalid")
                     end
        Rebase::State.new(branch, original_head, upstream, onto, todo,
          next_index, expected, keep_empty)
      ensure
        child.try &.close
        parent.close
      end
    end
  end
end
