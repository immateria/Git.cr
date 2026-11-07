require "set"

require "./stash/values"
require "./stash/save"
require "./stash/inspect"
require "./stash/apply"
require "./stash/drop"
require "./stash/worktree"
require "./stash/reflog"

module Git
  # The stash (`git stash`): saved worktree and index states, newest at
  # position 0. Obtained from Repository#stash.
  struct Stash
    def initialize(@repository : Repository)
    end

    # `git stash push`: save tracked changes (and with include_untracked or
    # include_ignored, those files too) and clean them from the worktree.
    # keep_index leaves the index as staged; staged_only stashes just the
    # staged changes; paths limits the stash to exact repository-relative
    # paths. Returns nil when there was nothing to save. The caller supplies
    # the identity and time. Conversion uses the supplied config or repository
    # local config; environment and clock are not read. warning receives each
    # safecrlf warning once per captured path, before stash publication.
    def push(*, actor : Signature, message : String? = nil, config : Config? = nil,
             warning : Proc(String, Nil)? = nil,
             include_untracked : Bool = false, include_ignored : Bool = false,
             keep_index : Bool = false, staged_only : Bool = false,
             paths : Array(String)? = nil,
             max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
             max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
             max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Entry?
      @repository.stash_push(actor: actor, message: message, config: config, warning: warning,
        include_untracked: include_untracked, include_ignored: include_ignored,
        keep_index: keep_index, staged_only: staged_only, paths: paths,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries,
        max_log_bytes: max_log_bytes, check: check)
    end

    # `git stash list`, newest first, up to limit entries.
    def list(*, limit : Int32 = 100, max_log_bytes : Int32 = 8_388_608,
             max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
             check : Proc(Nil)? = nil) : Array(Entry)
      @repository.stash_list(limit: limit, max_log_bytes: max_log_bytes,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
    end

    # The entry at position (`stash@{position}`).
    def show(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
             max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
             check : Proc(Nil)? = nil) : Entry
      @repository.stash_show(position, max_log_bytes: max_log_bytes,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
    end

    # `git stash apply`: replay an entry onto the worktree (and, with
    # restore_index, the index), keeping the entry.
    def apply(position : Int32 = 0, *, actor : Signature, restore_index : Bool = false,
              config : Config? = nil,
              max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
              max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Applied
      @repository.stash_apply(position, actor: actor, restore_index: restore_index, config: config,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries,
        max_log_bytes: max_log_bytes, check: check)
    end

    # `git stash pop`: apply, then drop the entry unless the application
    # left conflicts.
    def pop(position : Int32 = 0, *, actor : Signature, restore_index : Bool = false,
            config : Config? = nil,
            max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
            max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
            max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Popped
      @repository.stash_pop(position, actor: actor, restore_index: restore_index, config: config,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries,
        max_log_bytes: max_log_bytes, check: check)
    end

    # `git stash drop`. Returns the dropped entry.
    def drop(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
             max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
             check : Proc(Nil)? = nil) : Entry
      @repository.stash_drop(position, max_log_bytes: max_log_bytes,
        max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
    end
  end

  class Repository
    # The repository's stash.
    def stash : Stash
      Stash.new(self)
    end
  end
end
