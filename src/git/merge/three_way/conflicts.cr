module Git
  module Merge
    # A resolved merge has only stages 0; a conflicted merge records each
    # available base/ours/theirs side at stages 1/2/3 respectively.
    def self.conflict(path : String, base : Checkout::FileState?, ours : Checkout::FileState?,
                      theirs : Checkout::FileState?) : Index::PutStages
      entries = [] of Index::Entry
      {base, ours, theirs}.each_with_index do |state, index|
        entries << Index::Entry.new(path, state.mode, state.oid, index + 1, false, false) if state
      end
      Index::PutStages.new(path, entries)
    end

    def self.markers(repository : Repository, ours : Checkout::FileState?,
                     theirs : Checkout::FileState?, label : String,
                     max_bytes : Int32, check : Proc(Nil)?) : String?
      return nil unless ours && theirs && ours.mode == theirs.mode
      return nil unless {"100644", "100755"}.includes?(ours.mode)
      left_kind, left = repository.object(ours.oid, max_bytes) { check.try &.call }
      right_kind, right = repository.object(theirs.oid, max_bytes) { check.try &.call }
      return nil unless left_kind == "blob" && right_kind == "blob" && left.valid_encoding? &&
                        right.valid_encoding? && !left.includes?('\0') && !right.includes?('\0') &&
                        left.ends_with?("\n") && right.ends_with?("\n")
      return nil if left.bytesize.to_i64 + right.bytesize + label.bytesize + 64 > max_bytes
      "<<<<<<< HEAD\n#{left}=======\n#{right}>>>>>>> #{label}\n"
    end
  end
end
