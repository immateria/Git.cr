module Git
  module Checkout
    # Dangling targets are valid. The descriptor reader never follows a link
    # at the leaf or any ancestor.
    protected def self.symlink_target(root : String, path : String, max_bytes : Int32) : String
      dir, leaf, location = parent(root, path, create: false)
      begin
        raise Error.new("Git symlink parent replaced") unless dir.attached_at?(location)
        dir.read_symlink(leaf, max_bytes)
      ensure
        dir.close
      end
    end

    # Follow no symlinks, and refuse any existing leaf for a newly tracked
    # path, including directories and ignored files. Avoid even probing a
    # symlinked ancestor outside the checked worktree.
    protected def self.require_free_destination!(root : String, path : String) : Nil
      parent = root
      parts = path.split('/')
      parts[0...-1].each do |part|
        parent = File.join(parent, part)
        raise Error.new("Git checkout symlinked destination parent") if File.symlink?(parent)
        if File.exists?(parent)
          raise Error.new("Git checkout destination parent is not a directory") unless Dir.exists?(parent) && File.realpath(parent) == parent
        end
      end
      target = File.join(root, path)
      raise Error.new("Git checkout refuses untracked path collision") if File.exists?(target) || File.symlink?(target)
    end

    # Pinned descriptor parent for new paths; mkdirat never follows a symlink.
    protected def self.parent(root : String, path : String, *, create : Bool) : {DescriptorPath::Directory, String, String}
      parts = path.split('/')
      location = root
      dir = DescriptorPath::Directory.open(root)
      begin
        parts[0...-1].each do |component|
          if create && dir.stat?(component).nil?
            dir.mkdir_new(component)
            dir.sync
          end
          child = dir.open_directory(component)
          dir.close
          dir = child
          location = File.join(location, component)
        end
        raise Error.new("Git checkout parent replaced") unless dir.attached_at?(location)
        {dir, parts.last, location}
      rescue ex
        dir.close
        raise ex
      end
    end
  end
end
