module Git
  module References
    class Transaction
      # Delete one direct ref only if its observed OID still matches. This
      # removes both loose and packed representations to prevent a packed
      # value from resurfacing. Cooperative ref and packed-refs locks guard
      # preparation; separate filesystem publications are not crash-atomic.
      def self.delete(metadata : Metadata, format : ObjectId::Format,
                      name : String, expected_oid : String, *,
                      max_packed_bytes : Int32 = 8_388_608,
                      check : Proc(Nil)? = nil) : Nil
        # Use the same pinned ref/packed directory and ownership-checked
        # cleanup as mixed batches. A single delete has identical CAS and
        # packed-ref shadow-removal requirements.
        changes = [] of Change
        changes << Delete.new(name, expected_oid)
        change_many(metadata, format, changes,
          max_packed_bytes: max_packed_bytes, check: check)
      end
    end
  end
end
