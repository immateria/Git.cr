module Git
  module Checkout
    protected def self.tree_files(repository : Repository, tree_oid : String, *,
                                  max_object_bytes : Int32, max_files : Int32,
                                  check : Proc(Nil)?, allow_symlinks : Bool = false) : Hash(String, FileState)
      found = {} of String => FileState
      stack = [{"", tree_oid, 0}]
      visited = 0
      until stack.empty?
        check.try &.call
        prefix, oid, depth = stack.pop
        raise Error.new("Git checkout tree depth exceeded") if depth > Metadata::MAX_DEPTH
        kind, raw = repository.object(oid, max_object_bytes) { check.try &.call }
        raise Error.new("Git checkout expected tree") unless kind == "tree"
        repository.checkout_tree_entries(raw).each do |name, mode, entry_oid|
          visited += 1
          raise Error.new("Git checkout entry budget exceeded") if visited > max_files
          path = prefix + name
          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
          if mode == "40000"
            stack << {"#{path}/", entry_oid, depth + 1}
          else
            raise Error.new("Git checkout supports only regular files") unless {"100644", "100755"}.includes?(mode) ||
                                                                               (allow_symlinks && mode == "120000")
            raise Error.new("duplicate Git checkout path") if found.has_key?(path)
            found[path] = FileState.new(mode, entry_oid)
          end
        end
      end
      found
    end

    protected def self.path_collision(paths : Enumerable(String)) : {String, String}?
      sorted = paths.to_a.uniq.sort
      sorted.each_cons(2) do |pair|
        return {pair[0], pair[1]} if pair[1].starts_with?(pair[0] + "/")
      end
      nil
    end

    # Each individual Git tree/index view must still be free of D/F
    # collisions. A transition between two valid views is handled separately.
    protected def self.require_tree_paths!(paths : Enumerable(String), context : String = "Git tree") : Nil
      if pair = path_collision(paths)
        raise Error.new("#{context} file/directory collision: #{pair[0]} and #{pair[1]}")
      end
    end

    # Legacy conservative admission retained for reset/abort paths that have
    # not yet opted into transition planning.
    protected def self.require_compatible_paths!(old_paths : Array(String), new_paths : Array(String)) : Nil
      if pair = path_collision(old_paths + new_paths)
        raise Error.new("Git checkout file/directory transition unsupported: #{pair[0]} and #{pair[1]}")
      end
    end

    protected def self.path_prefixes(paths : Enumerable(String)) : Set(String)
      result = Set(String).new
      paths.each do |path|
        components = path.split('/')
        (1...components.size).each { |n| result.add(components.first(n).join('/')) }
      end
      result
    end
  end
end
