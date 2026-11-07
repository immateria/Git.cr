module Git
  # A merge stopped for conflict resolution. Obtained from Repository#merge
  # without arguments; Repository#merge(source, ...) starts one and
  # Repository#fast_forward advances without one.
  struct Merge
    def initialize(@repository : Repository)
    end

    # The merge in progress, or nil.
    def state? : State?
      @repository.merge_state?.try { |branch, ours, theirs| State.new(branch, ours, theirs) }
    end

    def in_progress? : Bool
      !@repository.merge_state?.nil?
    end

    # The unmerged index stages, one entry per conflicted path. A missing
    # side is nil.
    def conflicts(*, max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Array(Conflict)
      @repository.merge_conflicts(max_index_bytes: max_index_bytes, check: check)
    end

    # `git merge --continue`: commit the resolved index with both parents.
    # Returns the merge commit's ID.
    def continue(*, author : Signature, committer : Signature, message : String? = nil,
                 max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
                 check : Proc(Nil)? = nil) : String
      @repository.merge_continue(author: author, committer: committer, message: message,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
    end

    # `git merge --abort`: restore the index and worktree to the branch's
    # commit. Returns the paths it changed.
    def abort(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Array(String)
      @repository.merge_abort(config: config, max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
    end
  end

  class Repository
    # The merge in progress.
    def merge : Merge
      Merge.new(self)
    end
  end
end
