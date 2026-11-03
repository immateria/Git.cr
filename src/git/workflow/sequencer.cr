require "set"

require "./sequencer/values"
require "./sequencer/source"
require "./sequencer/initiate"
require "./sequencer/state"
require "./sequencer/continuation"
require "./sequencer/abort"
require "./sequencer/replay"
require "./sequencer/metadata"

module Git
  # A commit replay in progress (Git's sequencer): a cherry-pick, a revert or
  # the stopped step of a rebase. Repository#cherry_pick and #revert without
  # arguments give a handle limited to that kind; Repository#sequencer gives
  # one for whichever is in progress.
  struct Sequencer
    def initialize(@repository : Repository, @kind : Kind? = nil)
    end

    # The operation in progress, or nil (also nil when one of another kind
    # than this handle's is in progress).
    def state? : State?
      state = @repository.sequencer_state? || return nil
      kind = @kind
      kind.nil? || state.kind == kind ? state : nil
    end

    def in_progress? : Bool
      !state?.nil?
    end

    # The unmerged index stages left by the operation.
    def conflicts(*, max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Array(Merge::Conflict)
      require_state!
      @repository.sequencer_conflicts(max_index_bytes: max_index_bytes, check: check)
    end

    # `--continue`: commit the resolved index with the recorded author and
    # message (or message). Returns the new commit's ID.
    def continue(*, committer : Signature, message : String? = nil,
                 max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
                 check : Proc(Nil)? = nil) : String
      require_state!
      @repository.sequencer_continue(committer: committer, message: message,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
    end

    # `--abort`: restore the branch, index and worktree from before the
    # operation. Returns the paths it changed.
    def abort(*, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Array(String)
      require_state!
      @repository.sequencer_abort(max_object_bytes: max_object_bytes,
        max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, check: check)
    end

    # `--skip`: drop the current commit. With a single commit in the
    # sequence this restores the state from before the operation, as abort
    # does.
    def skip(*, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
             max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
             check : Proc(Nil)? = nil) : Array(String)
      abort(max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
    end

    private def require_state! : Nil
      label = @kind.try { |kind| kind.cherry_pick? ? "cherry-pick" : kind.revert? ? "revert" : "rebase" } || "sequencer operation"
      state = @repository.sequencer_state? || raise Error.new("no Git #{label} in progress")
      if (kind = @kind) && state.kind != kind
        raise Error.new("Git sequencer operation is not a #{label}")
      end
    end
  end

  class Repository
    # Whichever cherry-pick, revert or rebase step is in progress.
    def sequencer : Sequencer
      Sequencer.new(self)
    end

    # The cherry-pick in progress (`git cherry-pick --continue/--abort`).
    def cherry_pick : Sequencer
      Sequencer.new(self, Sequencer::Kind::CherryPick)
    end

    # The revert in progress (`git revert --continue/--abort`).
    def revert : Sequencer
      Sequencer.new(self, Sequencer::Kind::Revert)
    end
  end
end
