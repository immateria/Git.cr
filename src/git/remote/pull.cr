module Git
  # `git pull`: fetch the current branch's upstream, then integrate it.
  module Pull
    # How a pull integrates the fetched upstream.
    enum Mode
      # Only fast-forward; refuse diverged histories (`pull --ff-only`).
      FastForwardOnly
      # Fast-forward when possible, else a merge commit (`pull --no-rebase`).
      Merge
    end

    # What a pull did to the current branch.
    enum Action
      # The branch was unborn and now starts at the upstream.
      Initial
      UpToDate
      FastForward
      # A merge commit was made, or a conflicted merge was left to resolve.
      Merge
    end

    record Result, fetch : Fetch::Result, previous : String?, current : String?,
      action : Action, merge : Merge::Result? = nil
  end

  class Repository
    # `git pull`: fetch the current branch's upstream, then fast-forward or
    # merge it. Merges use the native three-way merge; a conflicted merge
    # stops with Git's merge state for merge_continue or merge_abort.
    def pull(*, mode : Pull::Mode = Pull::Mode::FastForwardOnly, transport : Transport? = nil,
             author : Signature? = nil, committer : Signature? = nil,
             actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
             max_entries : Int32 = 100_000, max_total_bytes : Int64 = 1_073_741_824,
             check : Proc(Nil)? = nil) : Pull::Result
      require_worktree!
      branch_ref = head_ref_and_oid[0] || raise Error.new("Git pull needs a checked-out branch")
      raise Error.new("Git pull needs a branch") unless branch_ref.starts_with?("refs/heads/")
      branch = branch_ref.byte_slice(11)
      remote_name, merge_ref = branch_upstream(branch) || raise Error.new("Git branch #{branch} has no upstream")
      fetched = fetch(remote_name, transport: transport, actor: actor, progress: progress, check: check)
      tracking = upstream_tracking_ref(remote_name, merge_ref) || raise Error.new("Git upstream #{merge_ref} is not fetched")
      target = resolve_ref?(tracking) || raise Error.new("Git upstream #{tracking} does not exist")
      previous = head_ref_and_oid[1]
      if previous.nil?
        update_ref(branch_ref, target, expected_oid: nil, max_object_bytes: 268_435_456)
        populate_worktree(target, max_files: max_entries, check: check)
        return Pull::Result.new(fetched, nil, target, Pull::Action::Initial)
      end
      return Pull::Result.new(fetched, previous, previous, Pull::Action::UpToDate) if previous == target
      walker = History::RevisionWalker.new(self, check: check)
      return Pull::Result.new(fetched, previous, previous, Pull::Action::UpToDate) if walker.ancestor?(target, previous)
      log = actor.try { |who| References::LogEntry.new(who, "pull: Fast-forward") }
      if walker.ancestor?(previous, target)
        fast_forward(target, log: log, max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2,
          max_total_bytes: max_total_bytes, max_entries: Math.min(max_entries, @max_search_entries), check: check)
        return Pull::Result.new(fetched, previous, target, Pull::Action::FastForward)
      end
      raise Error.new("Git pull cannot fast-forward #{branch}: histories diverged") if mode.fast_forward_only?
      who = author || raise Error.new("Git pull merge needs an author")
      message = "Merge branch '#{merge_ref.sub(/\Arefs\/heads\//, "")}' of #{remote(remote_name).url}\n"
      result = merge(target, author: who, committer: committer || who, message: message,
        max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2, max_total_bytes: max_total_bytes,
        max_entries: Math.min(max_entries, @max_search_entries), check: check)
      Pull::Result.new(fetched, previous, head_ref_and_oid[1], Pull::Action::Merge, result)
    end
  end
end
