module Git
  class Repository
    # Explicit compare-and-swap update of a single native reference. This
    # cannot be used to update HEAD symbolically or to bypass host admission.
    protected def update_ref(name : String, new_oid : String, *, expected_oid : String?,
                             log : References::LogEntry? = nil,
                             max_object_bytes : Int32 = 8_388_608,
                             check : Proc(Nil)? = nil) : Nil
      ObjectId.valid!(new_oid, @object_format)
      # Match Git update-ref's refusal to point at a missing/corrupt object.
      # The bound is caller-tunable for very large legitimate objects.
      @object_database.object(new_oid, max_object_bytes) { check.try &.call }
      References::Transaction.update(@metadata, @object_format, name,
        new_oid, expected_oid, log: log, check: check)
    end

    # Remove a direct reference by exact old-OID compare-and-swap, including
    # an existing packed entry and its peeled tag metadata. A deletion does
    # not remove objects, alter HEAD or invoke hooks/external helpers.
    protected def delete_ref(name : String, *, expected_oid : String,
                             max_packed_bytes : Int32 = 8_388_608,
                             check : Proc(Nil)? = nil) : Nil
      References::Transaction.delete(@metadata, @object_format, name, expected_oid,
        max_packed_bytes: max_packed_bytes, check: check)
    end

    # Apply direct-ref creations, updates and deletions in one coordinated
    # lock/expected-OID preflight. Deletions also rewrite packed-refs and
    # remove the deleted reflog. Cross-file publication is not crash-atomic;
    # a late failure raises References::PartialPublication with known effects.
    protected def change_refs(changes : Array(References::Change), *, max_changes : Int32 = 64,
                              max_object_bytes : Int32 = 8_388_608,
                              max_packed_bytes : Int32 = 8_388_608,
                              check : Proc(Nil)? = nil,
                              after_publish : Proc(String, Nil)? = nil) : Nil
      raise Error.new("Git reference transaction must not be empty") if changes.empty?
      raise Error.new("Git reference transaction budget exceeded") if max_changes < 1 || changes.size > max_changes
      changes.each do |change|
        next unless change.is_a?(References::Update)
        ObjectId.valid!(change.new_oid, @object_format)
        @object_database.object(change.new_oid, max_object_bytes) { check.try &.call }
      end
      References::Transaction.change_many(@metadata, @object_format, changes,
        max_changes: max_changes, max_packed_bytes: max_packed_bytes,
        check: check, after_publish: after_publish)
    end
  end
end
