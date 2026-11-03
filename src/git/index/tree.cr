module Git
  class Index
    # Build a hierarchical Git tree from stage-zero entries. Tree writing
    # is independent of ref updates and is usable without a host.
    class TreeBuilder
      @files = [] of Tree::Entry
      @directories = {} of String => TreeBuilder

      def add(entry : Entry) : Nil
        raise Error.new("cannot write tree with unmerged or intent-to-add index") if entry.stage != 0 || entry.intent
        parts = entry.path.split('/')
        node = self
        parts[0...-1].each do |component|
          node = node.directory(component)
        end
        raise Error.new("Git index tree collision") if node.has_directory?(parts.last)
        node.add_file(Tree::Entry.new(parts.last, entry.mode, entry.oid))
      end

      def write(repository : Repository, *, max_bytes : Int64 = Int64::MAX,
                check : Proc(Nil)? = nil) : String
        entries = @files.dup
        @directories.each do |name, child|
          check.try &.call
          oid = child.write(repository, max_bytes: max_bytes, check: check)
          entries << Tree::Entry.new(name, "40000", oid)
        end
        repository.write_tree(entries, max_bytes: max_bytes, check: check)
      end

      protected def directory(name : String) : TreeBuilder
        raise Error.new("Git index tree collision") if @files.any? { |file| file.name == name }
        @directories[name] ||= TreeBuilder.new
      end

      protected def has_directory?(name : String) : Bool
        @directories.has_key?(name)
      end

      protected def add_file(file : Tree::Entry) : Nil
        raise Error.new("duplicate Git index tree entry") if @files.any? { |previous| previous.name == file.name }
        @files << file
      end
    end
  end

  class Repository
    # Return an immutable tree object representing a stable read of the index.
    # Does not alter HEAD, index or refs. Refuse partial-conflict indexes.
    def write_index_tree(*, max_index_bytes : Int32 = 8_388_608,
                         max_tree_bytes : Int64 = Int64::MAX,
                         check : Proc(Nil)? = nil) : String
      check!
      current = @index.entries(max_index_bytes) { check.try &.call }
      builder = Index::TreeBuilder.new
      current.each { |entry| builder.add(entry) }
      builder.write(self, max_bytes: max_tree_bytes, check: check)
    end

    # Native first-parent commit of the current staged index, with an
    # expected-old-oid branch CAS. This is NOT a multi-file atomic transaction:
    # object writes can survive a CAS conflict; independent index changes
    # between snapshot and ref update remain outside this first slice.
    def commit(*, author : Signature, committer : Signature,
               message : String, allow_empty : Bool = false,
               max_index_bytes : Int32 = 8_388_608,
               max_object_bytes : Int64 = Int64::MAX,
               check : Proc(Nil)? = nil) : String
      check!
      raise Error.new("Git first-parent commit refuses in-progress merge") if merge_state?
      raise Error.new("Git first-parent commit refuses in-progress sequencer operation") if sequencer_state?
      raise Error.new("Git first-parent commit refuses in-progress rebase") if rebase_state?
      branch, previous = head_ref_and_oid
      raise Error.new("native commit requires a symbolic branch HEAD") unless branch && branch.starts_with?("refs/heads/")
      index_snapshot = @index.snapshot_checksum(max_index_bytes)
      if previous.nil? && !allow_empty && @index.entries(max_index_bytes) { check.try &.call }.empty?
        raise Error.new("nothing staged to commit")
      end
      tree = write_index_tree(max_index_bytes: max_index_bytes,
        max_tree_bytes: max_object_bytes, check: check)
      if previous && !allow_empty
        original = read_commit(previous, max_bytes: max_index_bytes, check: check)
        raise Error.new("nothing staged to commit") if original.tree == tree
      end
      parents = previous ? [previous] : [] of String
      oid = write_commit(tree: tree, parents: parents, author: author,
        committer: committer, message: message, max_bytes: max_object_bytes,
        check: check)
      subject = message.split("\n", 2).first
      prefix = previous ? "commit: " : "commit (initial): "
      log = References::LogEntry.new(committer, "#{prefix}#{subject}")
      checked = -> do
        check.try &.call
        raise Error.new("Git index changed during commit") unless @index.snapshot_checksum(max_index_bytes) == index_snapshot
      end
      checked.call
      update_ref(branch, oid, expected_oid: previous, log: log,
        check: checked)
      oid
    end
  end
end
