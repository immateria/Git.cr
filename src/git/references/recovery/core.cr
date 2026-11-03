module Git
  struct References
    struct Recovery
      # Durable, caller-initiated forward recovery for the files-reference backend.
      # This is a redo journal, NOT a claim of globally atomic filesystem writes.
      # The original mixed-ref writer remains the only publisher of Git refs.
      DIRECTORY               = "crystal-git-recovery"
      GUARD_FILE              = "active.lock"
      FINALIZATION_MAGIC      = "crystal-git-finalization-1"
      FINAL_LOCK_MAGIC        = "crystal-git-owned-final-lock-1"
      MAX_FINALIZATION_BYTES  = 600_000
      MAGIC                   = "crystal-git-ref-redo-2"
      MAGIC_V1                = "crystal-git-ref-redo-1"
      MAGIC_V3                = "crystal-git-index-ref-redo-3"
      MAX_INDEX_IMAGE_BYTES   = 8_388_608
      MAX_INDEX_JOURNAL_BYTES = MAX_BYTES + 2 * MAX_INDEX_IMAGE_BYTES + 1024
      MAX_BYTES               = 65_536
      MAX_CHANGES             =     64

      class Conflict < Git::Error
      end

      record Stored, changes : Array(Change), logs : Array(LogIntent), index : Index::Image? = nil
      # A durable, strictly scoped cleanup intent; it survives an abrupt exit
      # after .redo removal and identifies only locks created by this finalizer.
      record Finalization, token : String, redo_checksum : String,
        refs : Array({String, String?}), index_checksum : String?

      def self.validate!(changes : Array(Change), format : ObjectId::Format) : Nil
        raise Error.new("empty Git recovery transaction") if changes.empty?
        raise Error.new("Git recovery transaction exceeds entry budget") if changes.size > MAX_CHANGES
        previous = ""
        changes.sort_by(&.name).each do |change|
          RefName.valid!(change.name)
          raise Error.new("unsupported Git recovery ref scope") unless change.name.starts_with?("refs/")
          raise Error.new("oversized Git recovery ref") if change.name.bytesize > 4096
          if !previous.empty? && (change.name == previous || change.name.starts_with?(previous + "/"))
            raise Error.new("overlapping Git recovery refs")
          end
          previous = change.name
          if expected = change.expected_oid
            ObjectId.valid!(expected, format)
          end
          case change
          when Update
            change.log.try(&.encode(change.expected_oid || "0" * format.hexsize, change.new_oid))
            ObjectId.valid!(change.new_oid, format)
          when Delete
            ObjectId.valid!(change.expected_oid, format)
          end
        end
      end
    end
  end
end
