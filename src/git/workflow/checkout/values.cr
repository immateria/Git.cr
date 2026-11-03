module Git
  # Local, conservative checkout plumbing. This is a bounded files-backend
  # transition, not a worktree-wide atomic transaction or a Git CLI emulator.
  module Checkout
    record Result, reference : String, commit_oid : String, changed_paths : Array(String)
    record FileState, mode : String, oid : String
    record Write, path : String, mode : String, oid : String, data : String

    class PartialPublication < Git::Error
      getter changed_paths : Array(String)
      getter index_published : Bool
      getter original_error : Exception

      def initialize(@changed_paths : Array(String), @index_published : Bool, @original_error : Exception)
        super("Git checkout partially published (#{@original_error.class}); inspect working tree, index and HEAD")
      end
    end
  end
end
