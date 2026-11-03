require "./rebase/values"
require "./rebase/initiate"
require "./rebase/continuation"
require "./rebase/replay"
require "./rebase/preflight"
require "./rebase/publication"
require "./rebase/progress"
require "./rebase/metadata"

module Git
  # A rebase in progress. Obtained from Repository#rebase without
  # arguments; Repository#rebase(upstream, ...) starts one.
  struct Rebase
    def initialize(@repository : Repository)
    end

    # The rebase in progress, or nil.
    def state? : State?
      @repository.rebase_state?
    end

    def in_progress? : Bool
      !state?.nil?
    end

    # `git rebase --continue`: commit the resolved step and replay the rest.
    def continue(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
                 max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
                 max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Result
      @repository.rebase_continue(committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    # `git rebase --skip`: drop the stopped commit and replay the rest.
    def skip(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
             max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
             max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Result
      @repository.rebase_skip(committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    # `git rebase --abort`: return the branch, index and worktree to where
    # the rebase started. Returns the paths it changed.
    def abort(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
              max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
              max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Array(String)
      @repository.rebase_abort(committer: committer, max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end
  end

  class Repository
    # The rebase in progress.
    def rebase : Rebase
      Rebase.new(self)
    end
  end
end
