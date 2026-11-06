module Git
  # Git's dubious-ownership and protected safe.directory rules. The host is
  # responsible for authenticating the process identity and supplying trusted
  # system/global/command configuration. This check NEVER grants host tool
  # authorization or proves tenant ownership.
  class Repository
    module Admission
      # Where a repository was found, before any of its own configuration
      # is read: the point at which an ownership decision must be made
      # (Repository.new's before_config hook receives one).
      record Site, root : String, git_dir : String, bare : Bool, gitfile : String?

      record Identity, uid : String, sudo_uid : String? = nil do
        def owns?(owner_id : String) : Bool
          return true if uid == owner_id
          return false unless uid == "0"
          if supplemental = sudo_uid
            # Git parses SUDO_UID as a decimal uid_t, accepting a leading +,
            # leading zeroes and leading whitespace but not trailing junk.
            # Bound the result to Linux uid_t rather than trusting raw strings.
            if /\A[ \t\r\n]*\+?[0-9]+\z/.matches?(supplemental)
              value = supplemental.to_u64?
              return value.to_s == owner_id if value && value <= UInt32::MAX
            end
          end
          false
        end
      end

      # Git 2.47's bare-repository admission uses the last protected value and
      # only consults it for implicit bare discovery. Local repository config
      # cannot loosen the policy; invalid enum spellings fail closed.
      protected def self.require_implicit_bare_allowed!(config : Config) : Nil
        if entry = config.protected_entries("safe.barerepository").last?
          case entry.value
          when "all"      then return
          when "explicit" then raise Error.new("Git bare repository refused by safe.bareRepository=explicit")
          else                 raise Error.new("invalid protected safe.bareRepository setting")
          end
        end
      end

      protected def self.allowed?(repository : String, git_dir : String, bare : Bool,
                                  gitfile : String?, identity : Identity, config : Config, *,
                                  home : String? = nil, git_prefix : String? = nil) : Bool
        paths = bare ? [git_dir] : [repository, git_dir]
        paths << gitfile.not_nil! if gitfile
        return true if paths.all? { |path| identity.owns?(File.info(path, follow_symlinks: false).owner_id) }

        target = File.realpath(bare ? git_dir : repository)
        allowed = false
        config.protected_entries("safe.directory").each do |entry|
          value = entry.value
          next unless value
          if value.empty?
            allowed = false
            next
          end
          if value == "*"
            allowed = true
            next
          end
          expanded = interpolate(value, home, git_prefix)
          next unless expanded && Path[expanded].absolute?
          descendant = expanded.ends_with?("/*")
          path = descendant ? expanded.byte_slice(0, expanded.bytesize - 2) : expanded
          # Git canonicalizes both the entry and the selected repository.
          # A missing or inaccessible path is never an ownership exemption.
          begin
            normalized = File.realpath(path)
            if descendant
              allowed = true if target.starts_with?(normalized + File::SEPARATOR)
            else
              allowed = true if target == normalized
            end
          rescue File::Error
            next
          end
        end
        allowed
      rescue ex : File::Error
        raise Error.new("Git ownership admission cannot inspect repository: #{ex.class}")
      end

      private def self.interpolate(value : String, home : String?, git_prefix : String?) : String?
        if value.starts_with?("~/")
          return nil unless home && Path[home].absolute?
          File.expand_path(value.byte_slice(2, value.bytesize - 2), home)
        elsif value.starts_with?("%(prefix)/")
          return nil unless git_prefix && Path[git_prefix].absolute?
          File.expand_path(value.byte_slice(10, value.bytesize - 10), git_prefix)
        else
          value
        end
      end
    end
  end
end
