module Git
  class Repository
    # Apply one commit's parent->commit delta to HEAD and create a new
    # first-parent commit. A source merge commit requires mainline: 1..N.
    # The source author/date is preserved; the caller supplies the new
    # committer identity/date. Conflicts leave standard CHERRY_PICK_HEAD state.
    def cherry_pick(source : String, *, committer : Signature,
                    message : String? = nil, mainline : Int32? = nil,
                    allow_empty : Bool = false, config : Config? = nil,
                    max_object_bytes : Int32 = 8_388_608,
                    max_index_bytes : Int32 = 8_388_608,
                    max_total_bytes : Int64 = 67_108_864,
                    max_entries : Int32 = 10_000,
                    check : Proc(Nil)? = nil) : Sequencer::Result
      sequencer_start(Sequencer::Kind::CherryPick, source, committer: committer,
        author: nil, message: message, mainline: mainline, allow_empty: allow_empty, config: config || self.config,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
    end

    # Apply the inverse commit delta to HEAD. For a merge commit, mainline
    # identifies the parent whose side of the merge is retained. Root commits
    # are supported: reverting one applies commit->empty.
    def revert(source : String, *, author : Signature, committer : Signature,
               message : String? = nil, mainline : Int32? = nil,
               allow_empty : Bool = false, config : Config? = nil,
               max_object_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864,
               max_entries : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Sequencer::Result
      sequencer_start(Sequencer::Kind::Revert, source, committer: committer,
        author: author, message: message, mainline: mainline, allow_empty: allow_empty, config: config || self.config,
        max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
        max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
    end
  end
end
