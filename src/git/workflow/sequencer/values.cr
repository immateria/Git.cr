module Git
  # Single-commit history replay state shared by cherry-pick and revert. The
  # metadata layout is deliberately reusable for a future multi-item rebase
  # sequencer, while CHERRY_PICK_HEAD / REVERT_HEAD remain compatible with the
  # standard Git repository state model.
  struct Sequencer
    enum Kind
      CherryPick
      Revert
      Rebase
    end

    record Source, oid : String, tree : String, parents : Array(String),
      author : Signature, message : String
    record State, kind : Kind, branch : String, original_head : String,
      source : String, parent : String?, author : Signature, message : String,
      allow_empty : Bool
    record Result, kind : Kind, original_head : String, source : String,
      parent : String?, changed_paths : Array(String), conflicts : Array(String),
      commit_oid : String?

    # A syntactically valid replay whose resulting tree equals the original
    # HEAD. State intentionally remains present so the caller can either skip
    # it or explicitly continue when allow_empty was selected at start.
    class EmptyResult < Git::Error
      def initialize
        super("Git sequencer result is empty; skip or restart with allow_empty")
      end
    end

    class PartialPublication < Git::Error
      getter changed_paths : Array(String)
      getter index_published : Bool
      getter original_error : Exception

      def initialize(@changed_paths : Array(String), @index_published : Bool,
                     @original_error : Exception)
        super("Git sequencer partially published (#{@original_error.class}); inspect operation state, index and worktree")
      end
    end

    class PartialCommit < Git::Error
      getter commit_oid : String
      getter original_error : Exception

      def initialize(@commit_oid : String, @original_error : Exception)
        super("Git sequencer commit published but metadata cleanup failed; inspect HEAD and operation state")
      end
    end
  end
end
