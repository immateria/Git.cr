module Git
  struct Merge
    # :nodoc:
    # Recursive merge-base synthesis writes immutable, unreachable objects only.
    # No virtual commit is installed into HEAD, refs, the index or the worktree.
    class Bases
      MAX_DEPTH = 64
      @remaining : Int32

      def initialize(@repository : Repository, @max_history_nodes : Int32,
                     @max_object_bytes : Int32, @max_total_bytes : Int64,
                     @max_entries : Int32, @check : Proc(Nil)?)
        @remaining = @max_history_nodes
      end

      def combine(left : String, right : String, depth : Int32 = 0) : String
        @check.try &.call
        raise Error.new("Git recursive merge-base depth budget exceeded") if depth > MAX_DEPTH
        # The public merge_bases API sorts by OID. Recursive merging needs
        # Git's date/discovery order, reversed to fold the oldest base first;
        # OID sorting loses the stage-one conflict blob when dates tie.
        ordered = History::RevisionWalker.new(@repository, max_object_bytes: @max_object_bytes, check: @check)
          .merge_bases(left, right, max_nodes: @max_history_nodes).reverse
        result = ordered.first? || empty_commit
        ordered.skip(1).each do |other|
          @remaining -= 1
          raise Error.new("Git recursive merge-base work budget exceeded") if @remaining < 0
          ancestor = combine(result, other, depth + 1)
          base = files(ancestor)
          ours = files(result)
          theirs = files(other)
          names = (base.keys + ours.keys + theirs.keys).uniq.sort
          raise Error.new("Git recursive merge-base entry budget exceeded") if names.size > @max_entries
          renames = Merge.rename_plan(@repository, base, ours, theirs,
            max_object_bytes: @max_object_bytes, max_total_bytes: @max_total_bytes, check: @check,
            our_label: "Temporary merge branch 1", their_label: "Temporary merge branch 2",
            marker_size: 7 + 2 * (depth + 1), virtual: true)
          plan = Merge.plan_files(@repository, names, base, ours, theirs, renames,
            marker_label: "Temporary merge branch 2", marker_ours: "Temporary merge branch 1",
            marker_size: 7 + 2 * (depth + 1), operation: "Git recursive merge base",
            max_object_bytes: @max_object_bytes, max_total_bytes: @max_total_bytes, check: @check)
          merged = ours.dup
          plan.edits.each do |edit|
            case edit
            when Index::Remove
              merged.delete(edit.path)
            when Index::Put
              merged[edit.path] = Checkout::FileState.new(edit.mode, edit.oid)
            when Index::PutStages
              state = virtual_conflict(edit, depth + 1)
              if state
                merged[edit.path] = state
              else
                merged.delete(edit.path)
              end
            end
          end
          Checkout.require_tree_paths!(merged.keys, "Git recursive merge base")
          builder = Index::TreeBuilder.new
          merged.each do |path, state|
            builder.add(Index::Entry.new(path, state.mode, state.oid, 0, false, false))
          end
          tree = builder.write(@repository, max_bytes: @max_object_bytes, check: @check)
          result = virtual_commit(tree, [result, other])
        end
        result
      end

      private def virtual_conflict(edit : Index::PutStages, depth : Int32) : Checkout::FileState?
        stages = edit.stages
        states = (1..3).map do |stage|
          entry = stages.find { |item| item.stage == stage }
          entry ? Checkout::FileState.new(entry.mode, entry.oid) : nil
        end
        ancestor, local, remote = states
        return nil unless local || remote
        # Rename/delete conflict stages carry the ancestor at the destination,
        # not necessarily at a path present in the original base tree.
        return ancestor || local || remote unless local && remote
        return ancestor unless (local.mode == "120000") == (remote.mode == "120000")
        mode = local.mode == remote.mode || local.mode == ancestor.try(&.mode) ? remote.mode : local.mode
        # OID equality wins before type-specific fallback. Renames and mode
        # changes can reach this path even when the content is unchanged.
        oid = if local.oid == remote.oid || local.oid == ancestor.try(&.oid)
                remote.oid
              elsif remote.oid == ancestor.try(&.oid)
                local.oid
              end
        return Checkout::FileState.new(mode, oid) if oid
        # An unresolved symlink conflict restores the entire original state,
        # including its kind or absence; never attach its blob to a new mode.
        return ancestor if local.mode == "120000"
        original = ancestor && {"100644", "100755"}.includes?(ancestor.mode) ? ancestor : nil
        contents = {original, local, remote}.map do |state|
          if state
            kind, raw = @repository.object(state.oid, @max_object_bytes) { @check.try &.call }
            raise Error.new("Git virtual conflict expected blob") unless kind == "blob"
            raw
          else
            ""
          end
        end
        if contents.any?(&.includes?('\0'))
          oid = original.try(&.oid) || @repository.write_blob("", max_bytes: @max_object_bytes, check: @check)
          return Checkout::FileState.new(mode, oid)
        end
        if merged = Text.merge(contents[0], contents[1], contents[2])
          oid = @repository.write_blob(merged, max_bytes: @max_object_bytes, check: @check)
          return Checkout::FileState.new(mode, oid)
        end
        if marker = Merge.markers(@repository, Checkout::FileState.new(mode, local.oid),
             Checkout::FileState.new(mode, remote.oid), "Temporary merge branch 2",
             @max_object_bytes, @check, ours_label: "Temporary merge branch 1",
             marker_size: 7 + 2 * depth, allow_missing_newline: true)
          oid = @repository.write_blob(marker, max_bytes: @max_object_bytes, check: @check)
          return Checkout::FileState.new(mode, oid)
        end
        raise Error.new("Git virtual text conflict encoding or marker budget unsupported")
      end

      private def files(oid : String) : Hash(String, Checkout::FileState)
        tree = @repository.read_commit(oid, max_bytes: @max_object_bytes, check: @check).tree
        Checkout.tree_files(@repository, tree, max_object_bytes: @max_object_bytes,
          max_files: @max_entries, check: @check, allow_symlinks: true)
      end

      private def empty_commit : String
        tree = @repository.write_tree([] of Tree::Entry, max_bytes: @max_object_bytes, check: @check)
        virtual_commit(tree, [] of String)
      end

      private def virtual_commit(tree : String, parents : Array(String)) : String
        signature = Signature.new("Virtual merge base", "virtual@example.invalid", 0_i64, 0)
        @repository.write_commit(tree: tree, parents: parents, author: signature,
          committer: signature, message: "merged common ancestors\n",
          max_bytes: @max_object_bytes, check: @check)
      end
    end
  end
end
