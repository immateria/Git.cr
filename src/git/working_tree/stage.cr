module Git
  class WorkingTree
    # Explicit read of a single regular worktree file for staging. Does not
    # interpret attributes or run clean filters; those remain Git parity work.
    def stage_content(path : String, max_bytes : Int32, &check : -> Nil) : {String, String}
      oid, mode, bytes = read_working_regular(path, max_bytes) { check.call }
      {mode, bytes}
    end
  end

  class Repository
    # Native subset of git add -- <path>: explicit, existing regular files
    # and symlinks. A symlink's target bytes are staged without following it.
    # Ignore, attributes and pathspec expansion remain separate work.
    def stage_file(path : String, *, max_bytes : Int32 = 8_388_608,
                   max_index_bytes : Int32 = 8_388_608,
                   check : Proc(Nil)? = nil) : String
      require_worktree!
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      mode, bytes = if File.symlink?(File.join(@root, path))
                      {"120000", Checkout.symlink_target(@root, path, max_bytes)}
                    else
                      @worktree.stage_content(path, max_bytes) { check.try &.call }
                    end
      stage_blob(path, bytes, mode: mode, max_blob_bytes: max_bytes.to_i64,
        max_index_bytes: max_index_bytes, check: check)
    end
  end
end
