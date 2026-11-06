module Git
  # Line attribution for a committed file. Contents retain their LF byte, if
  # present; original and final line numbers are one-based.
  struct Blame
    record Line, commit_oid : String, original_path : String,
      original_line : Int32, final_line : Int32, content : String,
      author : Signature, committer : Signature, boundary : Bool do
      def boundary? : Bool
        boundary
      end
    end

    include Indexable(Line)

    getter revision : String
    getter path : String
    getter lines : Array(Line)
    # Distinct commits read, including parents inspected for attribution.
    getter scanned : Int32

    # :nodoc:
    def initialize(@revision : String, @path : String, @lines : Array(Line), @scanned : Int32)
    end

    def size : Int32
      @lines.size
    end

    def unsafe_fetch(index : Int) : Line
      @lines.unsafe_fetch(index)
    end

    # :nodoc:
    def self.build(repository : Repository, path : String, revision : String, *,
                   first_parent : Bool, follow_renames : Bool,
                   max_history_nodes : Int32, max_object_bytes : Int32,
                   max_total_bytes : Int64, max_entries : Int32,
                   max_lines : Int32, max_diff_work : Int64,
                   check : Proc(Nil)?) : Blame
      repository.check!
      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
      if max_history_nodes < 1 || max_object_bytes < 128 || max_total_bytes < 0 ||
         max_entries < 1 || max_lines < 0 || max_diff_work < 0
        raise ArgumentError.new("invalid Git blame budgets")
      end
      check.try &.call
      oid = Git::History.resolve_commit(repository, revision, max_object_bytes, check)
      work = TextDiff::Work.new(max_diff_work, check)
      history = History.new(repository, max_history_nodes, max_object_bytes,
        max_total_bytes, max_entries, max_lines, work, check)
      Walker.new(history, oid, path, first_parent, follow_renames,
        max_history_nodes, work, check).run
    end
  end

  class Repository
    # Attribute committed lines as ordinary Git blame does. Reads immutable
    # objects only, including symlink contents; never reads the working file.
    # max_history_nodes bounds distinct commits and commit/path origins;
    # max_total_bytes bounds cached object payloads, max_lines bounds lines in
    # distinct parsed blobs, and max_diff_work is shared by line comparisons.
    def blame(path : String, revision : String = "HEAD", *,
              first_parent : Bool = false, follow_renames : Bool = true,
              max_history_nodes : Int32 = 16_384,
              max_object_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864,
              max_entries : Int32 = 10_000, max_lines : Int32 = 1_000_000,
              max_diff_work : Int64 = 100_000_000,
              check : Proc(Nil)? = nil) : Blame
      Blame.build(self, path, revision, first_parent: first_parent,
        follow_renames: follow_renames, max_history_nodes: max_history_nodes,
        max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
        max_entries: max_entries, max_lines: max_lines,
        max_diff_work: max_diff_work, check: check)
    end
  end
end

require "./blame/history"
require "./blame/walker"
