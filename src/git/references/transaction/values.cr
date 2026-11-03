module Git
  # Independent Git reference storage. The host's authorization and action
  # grants live outside this library. P19 currently supports atomic publication
  # of loose refs. Batches coordinate locks and verify every expectation
  # before publication; files-backend renames are not crash-atomic as a group.
  struct References
    record LogEntry, actor : Signature, message : String do
      def encode(old_oid : String, new_oid : String) : String
        raise Error.new("invalid Git reflog message") if message.each_byte.any? { |b| b == 0 || b == 10 || b == 13 }
        "#{old_oid} #{new_oid} #{actor.to_git_header}\t#{message}\n"
      end
    end

    # A concrete direct-reference change. nil expected_oid means the ref
    # must not exist. Deletes, symbolic rewrites and hidden force updates
    # are separate operations, not implied by this value type.
    record Update, name : String, new_oid : String, expected_oid : String?, log : LogEntry? = nil
    record Delete, name : String, expected_oid : String
    alias Change = Update | Delete

    # A prepared transaction can still partially publish if a later rename,
    # deletion, directory sync, or reflog operation fails. This error exposes
    # what the writer knows has already happened; callers must re-read all
    # refs and logs before retrying. It is not a rollback guarantee.
    class PartialPublication < Git::Error
      getter published_refs : Array(String)
      getter packed_published : Bool
      getter reflogs_started : Bool
      getter original_error : Exception

      def initialize(@published_refs : Array(String), @packed_published : Bool,
                     @reflogs_started : Bool, @original_error : Exception)
        super("Git reference transaction partially published (#{@original_error.class})")
      end
    end
  end
end
