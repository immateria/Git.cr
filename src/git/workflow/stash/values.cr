module Git
  struct Stash
    REF = "refs/stash"

    record Entry, position : Int32, oid : String, base_oid : String,
      index_oid : String, tree : String, index_tree : String,
      message : String, untracked_oid : String?

    # What applying an entry did to the index and worktree.
    record Applied, entry : Entry, changed_paths : Array(String),
      conflicts : Array(String), index_restored : Bool

    # An application followed by dropping the entry.
    record Popped, applied : Applied, dropped : Bool

    # :nodoc:
    record LogRecord, old_oid : String, new_oid : String,
      identity : String, message : String do
      def encode : String
        "#{old_oid} #{new_oid} #{identity}\t#{message}\n"
      end
    end

    class PartialSave < Git::Error
      getter stash_oid : String
      getter changed_paths : Array(String)
      getter index_published : Bool
      getter original_error : Exception

      def initialize(@stash_oid : String, @changed_paths : Array(String),
                     @index_published : Bool, @original_error : Exception)
        super("Git stash saved but worktree cleanup partially published (#{@original_error.class}); inspect refs/stash, index and worktree")
      end
    end

    class PartialApply < Git::Error
      getter stash_oid : String
      getter changed_paths : Array(String)
      getter conflicts : Array(String)
      getter index_restored : Bool
      getter original_error : Exception

      def initialize(@stash_oid : String, @changed_paths : Array(String),
                     @conflicts : Array(String), @index_restored : Bool,
                     @original_error : Exception)
        super("Git stash apply partially published (#{@original_error.class}); inspect index and worktree; stash entry is retained")
      end
    end

    class PartialDrop < Git::Error
      getter stash_oid : String
      getter ref_published : Bool
      getter original_error : Exception

      def initialize(@stash_oid : String, @ref_published : Bool,
                     @original_error : Exception)
        super("Git stash drop partially published (#{@original_error.class}); inspect refs/stash and its reflog")
      end
    end

    class PartialPop < Git::Error
      getter applied : Applied
      getter original_error : Exception

      def initialize(@applied : Applied, @original_error : Exception)
        super("Git stash applied but drop failed (#{@original_error.class}); inspect refs/stash before retrying")
      end
    end
  end
end
