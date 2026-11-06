module Git
  struct Merge
    # :nodoc:
    # A durable description of outputs admitted before publication. A path
    # alone is not evidence that an unindexed file belongs to this operation.
    module Recovery
      MAGIC         = "\0git-merge-worktree-v1\0"
      STATE_VERSION = "worktree-v1"
      record Receipt, paths : Array(String), outputs : Hash(String, Checkout::FileState)
      record View, observations : Hash(String, Checkout::FileState?), directories : Set(String), bytes : Int64 do
        def leaves : Array(String)
          observations.keys.select { |path| !observations[path].nil? }
        end

        def preflight!(root : String, goals : Array(String), max_entries : Int32) : Nil
          present = leaves
          goals.each do |path|
            next if observations[path]? || present.any? { |leaf| path.starts_with?(leaf + "/") }
            if directories.includes?(path)
              Checkout.require_collapsible_directory!(root, path, present, max_entries,
                known_directories: directories)
            else
              Checkout.require_free_destination!(root, path)
            end
          end
        end

        def transition_directories(goals : Array(String)) : Array(String)
          directories.select do |directory|
            goals.any? { |path| directory == path || directory.starts_with?(path + "/") }
          end.to_a.sort_by { |path| {-path.count('/'), -path.bytesize, path} }
        end
      end

      def self.encode(paths : Array(String), writes : Array(Checkout::Write), ours : String, theirs : String,
                      format : ObjectId::Format, max_bytes : Int32, max_entries : Int32) : String
        fields = [ours, theirs, paths.size.to_s, writes.size.to_s] + paths
        writes.each { |write| fields.concat([write.path, write.mode, write.oid]) }
        raw = MAGIC + fields.join('\0')
        decode(raw, ours, theirs, format, max_bytes, max_entries)
        raw
      end

      def self.decode(raw : String?, ours : String, theirs : String, format : ObjectId::Format,
                      max_bytes : Int32, max_entries : Int32) : Receipt
        raise Error.new("Git worktree recovery metadata budget exceeded") if raw && raw.bytesize > max_bytes
        unless raw && raw.starts_with?(MAGIC)
          paths = Merge.decode_relocations(raw)
          raise Error.new("Git worktree recovery path budget exceeded") if paths.size > max_entries
          return Receipt.new(paths, {} of String => Checkout::FileState)
        end
        fields = raw.byte_slice(MAGIC.bytesize).split('\0')
        raise Error.new("Git worktree recovery identity changed") unless fields.size >= 4 && fields[0] == ours && fields[1] == theirs
        count = fields[2].to_i?
        raise Error.new("Git worktree recovery path count invalid") unless count && count >= 0 && count <= max_entries && count <= fields.size - 4
        output_count = fields[3].to_i?
        raise Error.new("Git worktree recovery output count invalid") unless output_count && output_count >= 0 && output_count <= max_entries
        paths = fields[4, count]
        Merge.encode_relocations(paths)
        raise Error.new("Git worktree recovery duplicate path") unless paths.uniq.size == paths.size
        records = fields.skip(4 + count)
        raise Error.new("Git worktree recovery output count invalid") unless records.size.to_i64 == output_count.to_i64 * 3
        outputs = {} of String => Checkout::FileState
        records.each_slice(3) do |entry|
          path, mode, oid = entry
          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
          raise Error.new("Git worktree recovery output mode invalid") unless {"100644", "100755", "120000"}.includes?(mode)
          ObjectId.valid!(oid, format)
          raise Error.new("Git worktree recovery duplicate output") if outputs.has_key?(path)
          outputs[path] = Checkout::FileState.new(mode, oid)
        end
        Receipt.new(paths, outputs)
      end

      def self.require_versioned!(admin : DescriptorPath::Directory, name : String) : Nil
        io = admin.open_file?(name, LibC::O_RDONLY | LibC::O_NONBLOCK) ||
             raise Error.new("Git required worktree recovery metadata missing")
        begin
          raise Error.new("Git worktree recovery metadata not regular") unless io.info.type.file?
          prefix = Bytes.new(MAGIC.bytesize)
          unless io.read_fully?(prefix) && prefix == MAGIC.to_slice
            raise Error.new("Git required worktree recovery metadata format invalid")
          end
        ensure
          io.close unless io.closed?
        end
      end

      def self.read(admin : DescriptorPath::Directory, name : String, max_bytes : Int32) : String?
        # O_NONBLOCK makes a substituted FIFO rejectable before a blocking
        # open can strand recovery; regular-file reads retain normal behavior.
        io = admin.open_file?(name, LibC::O_RDONLY | LibC::O_NONBLOCK)
        return nil unless io
        begin
          raise Error.new("Git worktree recovery metadata not regular") unless io.info.type.file?
          raise Error.new("Git worktree recovery metadata budget exceeded") if io.info.size > max_bytes
          raw = IO::Memory.new
          IO.copy(io, raw, max_bytes.to_i64 + 1)
          raise Error.new("Git worktree recovery metadata budget exceeded") if raw.size > max_bytes
          raw.to_s
        ensure
          io.close unless io.closed?
        end
      end

      def self.observe(repository : Repository, current : Array(Index::Entry),
                       goals : Hash(String, Checkout::FileState), receipt : Receipt, *,
                       max_object_bytes : Int32, max_total_bytes : Int64,
                       max_entries : Int32, check : Proc(Nil)?) : View
        indexed = current.map(&.path).to_set
        candidates = (indexed.to_a + goals.keys + receipt.paths + receipt.outputs.keys).uniq.sort
        raise Error.new("Git worktree recovery path budget exceeded") if candidates.size > max_entries * 3
        known_dirs = Checkout.path_prefixes(candidates)
        directories = Set(String).new
        observations = {} of String => Checkout::FileState?
        total = 0_i64
        candidates.each do |path|
          check.try &.call
          blocked = false
          parts = path.split('/')
          (1...parts.size).each do |size|
            prefix = parts.first(size).join('/')
            if observations[prefix]?
              blocked = true # An observed owned leaf blocks this descendant.
              break
            end
            absolute = File.join(repository.root, prefix)
            raise Error.new("Git recovery symlinked parent") if File.symlink?(absolute)
            if File.exists?(absolute)
              raise Error.new("Git recovery parent not directory") unless Dir.exists?(absolute)
              directories.add(prefix)
            else
              blocked = true
              break
            end
          end
          state = nil.as(Checkout::FileState?)
          absolute = File.join(repository.root, path)
          unless blocked
            if Dir.exists?(absolute) && !File.symlink?(absolute)
              raise Error.new("Git recovery refuses untracked directory") unless known_dirs.includes?(path)
              directories.add(path)
            elsif File.exists?(absolute) || File.symlink?(absolute)
              mode, data = if File.symlink?(absolute)
                             {"120000", Checkout.symlink_target(repository.root, path, max_object_bytes)}
                           else
                             repository.checkout_working_regular(path, max_object_bytes) { check.try &.call }
                           end
              total += data.bytesize
              raise Error.new("Git worktree recovery total byte budget exceeded") if total > max_total_bytes
              state = Checkout::FileState.new(mode, ObjectId.digest("blob", data, repository.object_format))
              unless indexed.includes?(path) || receipt.outputs[path]? == state || goals[path]? == state
                raise Error.new("Git recovery refuses untracked or changed unpublished output: #{path}")
              end
            end
          end
          observations[path] = state
        end
        View.new(observations, directories, total)
      end
    end
  end
end
