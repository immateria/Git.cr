module Git
  struct Merge
    # A merge stopped for conflict resolution: the branch it is on, that
    # branch's commit when the merge started and the commit being merged
    # (MERGE_HEAD).
    record State, branch : String, ours : String, theirs : String

    record Result, ours : String, theirs : String, base : String?,
      changed_paths : Array(String), conflicts : Array(String), commit_oid : String?
    record Conflict, path : String, base : Checkout::FileState?,
      ours : Checkout::FileState?, theirs : Checkout::FileState?

    # A failed multi-file publication must retain MERGE_HEAD so that the
    # caller can inspect or explicitly abort, never silently assume rollback.
    class PartialPublication < Git::Error
      getter changed_paths : Array(String)
      getter index_published : Bool
      getter original_error : Exception

      def initialize(@changed_paths : Array(String), @index_published : Bool, @original_error : Exception)
        super("Git three-way merge partially published (#{@original_error.class}); inspect MERGE_HEAD, index and worktree")
      end
    end

    class PartialCommit < Git::Error
      getter commit_oid : String
      getter original_error : Exception

      def initialize(@commit_oid : String, @original_error : Exception)
        super("Git merge commit published but metadata cleanup failed; inspect HEAD and MERGE_HEAD")
      end
    end
  end
end
