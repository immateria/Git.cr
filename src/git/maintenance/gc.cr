module Git
  # `git gc` without pruning unreachable objects.
  module Gc
    record Result, packed_refs : Int32, repack : Repack::Result
  end

  class Repository
    # `git gc` without pruning unreachable loose objects: pack refs, repack
    # into one pack and remove loose objects that are packed.
    def gc(*, check : Proc(Nil)? = nil) : Gc::Result
      packed = pack_refs(check: check)
      Gc::Result.new(packed, repack(check: check))
    end
  end
end
