module Git
  # Bounded non-interactive rebase state. This first native lane deliberately
  # replays a linear first-parent commit stack; merge-preserving/interactive
  # todo syntax is outside this checkpoint.
  module Rebase
    record State, branch : String, original_head : String, upstream : String,
      onto : String, todo : Array(String), next_index : Int32,
      expected_head : String, keep_empty : Bool

    record Result, branch : String, original_head : String, onto : String,
      current_head : String, next_index : Int32, total : Int32,
      conflicts : Array(String), completed : Bool

    class PartialPublication < Git::Error
      getter changed_paths : Array(String)
      getter reference_published : Bool
      getter index_published : Bool
      getter original_error : Exception

      def initialize(@changed_paths : Array(String), @reference_published : Bool,
                     @index_published : Bool, @original_error : Exception)
        super("Git rebase partially published (#{@original_error.class}); inspect branch, index, worktree and rebase state")
      end
    end

    class PartialProgress < Git::Error
      getter source : String
      getter new_head : String
      getter original_error : Exception

      def initialize(@source : String, @new_head : String, @original_error : Exception)
        super("Git rebase replay commit published but progress metadata did not advance; inspect HEAD and rebase state")
      end
    end
  end
end
