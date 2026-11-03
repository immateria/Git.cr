module Git
  # A repository's configured remotes (`git remote`). Obtained from
  # Repository#remotes.
  struct Remotes
    def initialize(@repository : Repository)
    end

    # Remote names in the order the configuration first mentions them.
    def names : Array(String)
      @repository.remote_names
    end

    def [](name : String) : Remote
      @repository.remote(name)
    end

    def []?(name : String) : Remote?
      @repository.remote?(name)
    end

    # `git remote add`: the URL and the default (or given) fetch refspecs.
    def add(name : String, url : String, *, fetch : Array(String)? = nil,
            tag_mode : Remote::TagMode = Remote::TagMode::Auto) : Remote
      @repository.add_remote(name, url, fetch: fetch, tag_mode: tag_mode)
    end

    # `git remote remove`: the configuration, its remote-tracking refs and
    # the branch upstream settings that name it.
    def remove(name : String) : Nil
      @repository.remove_remote(name)
    end

    # `git remote rename`: configuration, default refspecs, tracking refs
    # and branch upstreams move to the new name.
    def rename(old_name : String, new_name : String) : Nil
      @repository.rename_remote(old_name, new_name)
    end

    # `git remote set-url` (`--push` with push).
    def set_url(name : String, url : String, *, push : Bool = false) : Nil
      @repository.set_remote_url(name, url, push: push)
    end
  end

  class Repository
    # The repository's configured remotes.
    def remotes : Remotes
      Remotes.new(self)
    end
  end
end
