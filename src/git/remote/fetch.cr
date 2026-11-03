require "set"

module Git
  # `git fetch`: what each fetched reference did and what was received.
  module Fetch
    # One reference a fetch looked at.
    record Update, remote_ref : String, local_ref : String?, old_oid : String?,
      new_oid : String, status : Update::Status, reason : String? = nil do
      enum Status
        New
        FastForward
        Forced
        UpToDate
        Rejected
        # Recorded only in FETCH_HEAD (no local destination).
        FetchHeadOnly
        Pruned
      end

      def applied? : Bool
        status.new? || status.fast_forward? || status.forced? || status.pruned?
      end
    end

    # The outcome of a fetch: per-ref updates, the pack stored (nil when
    # nothing was transferred), the remote's HEAD target and refs, and the
    # shallow boundary it reported.
    record Result, url : String, updates : Array(Update),
      pack : Pack::Published?, remote_head : String?, remote_refs : Array(Protocol::RemoteRef),
      shallow : Array(String) do
      def rejected : Array(Update)
        updates.select(&.status.rejected?)
      end

      def object_count : Int32
        pack.try(&.object_count) || 0
      end
    end

    # :nodoc:
    # How one remote ref maps to a local ref under the refspecs.
    record Mapping, ref : Protocol::RemoteRef, destination : String?, force : Bool,
      for_merge : Bool, auto_tag : Bool = false
  end

  class Repository
    # `git ls-remote`: the references (and HEAD) of a configured remote or
    # a transport, optionally only those under prefixes.
    def ls_remote(remote : String | Transport = "origin",
                  prefixes : Array(String) = [] of String) : Array(Protocol::RemoteRef)
      transport = remote.is_a?(Transport) ? remote : Transport.for_url(remote(remote).url)
      connection = transport.connect(Transport::Service::UploadPack)
      begin
        Protocol::UploadPack::Client.new(connection).ls_refs(prefixes)
      ensure
        connection.close
      end
    end

    # `git fetch <remote> [<refspec>...]` from a configured remote (by
    # name) or a transport. For a named remote, refspecs, tags and prune
    # default to its configuration and transport overrides how it is
    # reached; a transport needs explicit refspecs. Remote-tracking refs are
    # updated under Git's rules (fast-forward unless forced; tags are never
    # clobbered unless forced; the checked-out branch is protected). With an
    # actor, reflog entries are written. No hooks run and no credentials
    # are looked up.
    def fetch(remote : String | Transport = "origin", refspecs : Array(String)? = nil, *,
              transport : Transport? = nil,
              tags : Remote::TagMode? = nil, prune : Bool? = nil,
              depth : Int32? = nil, force : Bool = false,
              actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
              write_fetch_head : Bool = true, update_head_ok : Bool = false,
              check : Proc(Nil)? = nil) : Fetch::Result
      if remote.is_a?(Transport)
        raise ArgumentError.new("transport: applies to a named Git remote") if transport
        specs = refspecs || raise ArgumentError.new("Git fetch from a transport needs refspecs")
        return fetch_with(remote, specs, label: remote.url, url: remote.url,
          tags: tags || Remote::TagMode::Auto, prune: prune || false,
          depth: depth, force: force, actor: actor, progress: progress,
          write_fetch_head: write_fetch_head, update_head_ok: update_head_ok,
          explicit: true, check: check)
      end
      configured = remote(remote)
      selected = transport || Transport.for_url(configured.url)
      specs = (refspecs || configured.fetch_refspecs.map(&.to_s))
      fetch_with(selected, specs, label: remote, url: configured.url,
        tags: tags || configured.tag_mode, prune: prune.nil? ? (configured.prune || false) : prune,
        depth: depth, force: force, actor: actor, progress: progress,
        write_fetch_head: write_fetch_head, update_head_ok: update_head_ok,
        explicit: !refspecs.nil?, check: check)
    end

    protected def fetch_with(transport : Transport, spec_texts : Array(String), *,
                             label : String, url : String, tags : Remote::TagMode, prune : Bool,
                             depth : Int32?, force : Bool, actor : Signature?,
                             progress : Proc(String, Nil)?, write_fetch_head : Bool,
                             update_head_ok : Bool, explicit : Bool,
                             check : Proc(Nil)?) : Fetch::Result
      check!
      raise ArgumentError.new("invalid Git fetch depth") if depth && depth < 1
      specs = spec_texts.map { |text| Remote::Refspec.parse(text, fetch: true) }
      specs << Remote::Refspec.parse("refs/tags/*:refs/tags/*") if tags.all?
      connection = transport.connect(Transport::Service::UploadPack)
      begin
        client = Protocol::UploadPack::Client.new(connection)
        unless client.object_format == @object_format
          raise Error.new("Git remote uses #{client.object_format}, this repository #{@object_format}")
        end
        remote_refs = client.ls_refs(fetch_prefixes(specs, tags))
        remote_head = remote_refs.find { |ref| ref.name == "HEAD" }
        mappings = map_remote_refs(specs, remote_refs, explicit)
        auto_tags = tags.auto? ? remote_refs.select { |ref| ref.name.starts_with?("refs/tags/") && !ref.name.ends_with?("^{}") && ref.oid } : [] of Protocol::RemoteRef

        current_shallow = shallow_commits
        wants = mappings.compact_map(&.ref.oid).uniq.reject { |oid| has_object?(oid) }
        stored = nil.as(Pack::Published?)
        outcome = nil.as(Protocol::UploadPack::FetchOutcome?)
        if !wants.empty? || depth
          tips = references("refs/").compact_map(&.oid)
          head.oid.try { |oid| tips << oid }
          negotiator = Protocol::UploadPack::Negotiator.new(self, tips.uniq, check)
          wanted = wants.empty? ? mappings.compact_map(&.ref.oid).uniq : wants
          outcome = client.fetch(wanted, negotiator, include_tag: !tags.none?, depth: depth,
            shallow: current_shallow.to_a.sort, progress: progress) do |stream|
            stored = index_pack(stream, keep: "fetch-pack #{Process.pid}", check: check)
          end
          update_shallow(current_shallow, outcome.shallow, outcome.unshallow)
        end

        # Backfill annotated tags whose targets are present but whose tag
        # objects were not sent (Git's backfill_tags).
        if tags.auto?
          missing = auto_tags.select do |ref|
            target = ref.peeled || ref.oid.not_nil!
            has_object?(target) && !has_object?(ref.oid.not_nil!) && resolve_ref?(ref.name).nil?
          end.compact_map(&.oid).uniq
          unless missing.empty?
            client.fetch(missing, nil, include_tag: false, shallow: shallow_commits.to_a.sort, progress: progress) do |stream|
              backfilled = index_pack(stream, keep: "fetch-pack #{Process.pid}", check: check)
              release_pack_keep(backfilled)
            end
          end
          auto_tags.each do |ref|
            oid = ref.oid.not_nil!
            target = ref.peeled || oid
            next unless has_object?(oid) && has_object?(target)
            # Git follows only tags it does not have yet.
            next if resolve_ref?(ref.name)
            next if mappings.any? { |mapping| mapping.destination == ref.name }
            mappings << Fetch::Mapping.new(ref, ref.name, false, false, auto_tag: true)
          end
        end

        verify_connectivity(mappings.compact_map(&.ref.oid).uniq, check)
        updates = apply_fetch_updates(mappings, label, actor, force, update_head_ok, check)
        updates.concat(prune_tracking_refs(specs, remote_refs, actor, check)) if prune
        write_fetch_head_file(mappings, url) if write_fetch_head && !mappings.empty?
        stored.try { |pack| release_pack_keep(pack) }
        Fetch::Result.new(url, updates, stored, remote_head.try(&.symref_target), remote_refs,
          outcome.try(&.shallow) || [] of String)
      ensure
        connection.close
      end
    end

    private def fetch_prefixes(specs : Array(Remote::Refspec), tags : Remote::TagMode) : Array(String)
      prefixes = ["HEAD"]
      specs.each do |spec|
        next if spec.negative?
        source = spec.source
        if Remote::Refspec.object_id?(source)
          next
        elsif spec.pattern?
          prefixes << source.byte_slice(0, source.index('*').not_nil!)
        elsif source.starts_with?("refs/")
          prefixes << source
        else
          RefName::REV_PARSE_RULES.each { |rule| prefixes << rule.sub("%s", source) }
        end
      end
      prefixes << "refs/tags/" unless tags.none?
      prefixes.uniq
    end

    private def map_remote_refs(specs : Array(Remote::Refspec), remote_refs : Array(Protocol::RemoteRef),
                                explicit : Bool) : Array(Fetch::Mapping)
      names = remote_refs.map(&.name)
      negatives = specs.select(&.negative?)
      excluded = ->(name : String) { negatives.any?(&.source_matches?(name)) }
      mappings = [] of Fetch::Mapping
      destinations = {} of String => String
      specs.each do |spec|
        next if spec.negative?
        if spec.pattern?
          remote_refs.each do |ref|
            next if ref.name == "HEAD" || ref.oid.nil? || excluded.call(ref.name)
            destination = spec.map_source(ref.name) || next
            mappings << Fetch::Mapping.new(ref, destination, spec.force?, false)
          end
        else
          source = spec.source
          ref = if Remote::Refspec.object_id?(source)
                  ObjectId.valid!(source, @object_format)
                  Protocol::RemoteRef.new(source, source)
                else
                  full = if source.starts_with?("refs/") || source == "HEAD"
                           names.includes?(source) ? source : nil
                         else
                           RefName.expand(source, names)
                         end
                  raise Error.new("Git couldn't find remote ref #{source}") unless full
                  remote_refs.find { |candidate| candidate.name == full }.not_nil!
                end
          next if excluded.call(ref.name)
          raise Error.new("Git remote ref #{ref.name} is unborn") unless ref.oid
          destination = spec.destination.try do |dst|
            if dst.starts_with?("refs/") || dst == "HEAD"
              dst
            elsif ref.name.starts_with?("refs/tags/")
              "refs/tags/#{dst}"
            else
              "refs/heads/#{dst}"
            end
          end
          mappings << Fetch::Mapping.new(ref, destination, spec.force?, explicit)
        end
      end
      mappings.each do |mapping|
        destination = mapping.destination || next
        if (previous = destinations[destination]?) && previous != mapping.ref.name
          raise Error.new("Git fetch maps both #{previous} and #{mapping.ref.name} to #{destination}")
        end
        destinations[destination] = mapping.ref.name
      end
      # Mark the configured upstream of the current branch for merge.
      unless explicit
        if (branch_ref = head_ref_and_oid[0]) && branch_ref.starts_with?("refs/heads/")
          if upstream = branch_upstream(branch_ref.byte_slice(11))
            mappings = mappings.map do |mapping|
              mapping.ref.name == upstream[1] ? mapping.copy_with(for_merge: true) : mapping
            end
          end
        end
      end
      mappings.uniq { |mapping| {mapping.ref.name, mapping.destination} }
    end

    # Every object reachable from the new tips must be present (Git's
    # check_connected after a fetch).
    private def verify_connectivity(tips : Array(String), check : Proc(Nil)?) : Nil
      return if tips.empty?
      existing = references("refs/").compact_map(&.oid).reject { |oid| tips.includes?(oid) }
      items = History::RevisionWalker.new(self, check: check).objects(tips, existing.select { |oid| has_object?(oid) })
      items.each do |item|
        next unless item.type == "blob"
        raise Error.new("Git fetch is missing object #{item.oid} (#{item.path})") unless has_object?(item.oid)
      end
    end

    private def apply_fetch_updates(mappings : Array(Fetch::Mapping), label : String, actor : Signature?,
                                    force : Bool, update_head_ok : Bool,
                                    check : Proc(Nil)?) : Array(Fetch::Update)
      updates = [] of Fetch::Update
      changes = [] of References::Change
      current_branch = bare? ? nil : head_ref_and_oid[0]
      walker = History::RevisionWalker.new(self, check: check)
      mappings.each do |mapping|
        new_oid = mapping.ref.oid.not_nil!
        destination = mapping.destination
        unless destination
          updates << Fetch::Update.new(mapping.ref.name, nil, nil, new_oid, Fetch::Update::Status::FetchHeadOnly)
          next
        end
        old = resolve_ref?(destination)
        status, reason = if old == new_oid
                           {Fetch::Update::Status::UpToDate, nil}
                         elsif destination == current_branch && !update_head_ok
                           {Fetch::Update::Status::Rejected, "refusing to fetch into branch checked out"}
                         elsif old.nil?
                           {Fetch::Update::Status::New, nil}
                         elsif destination.starts_with?("refs/tags/") && !(force || mapping.force)
                           {Fetch::Update::Status::Rejected, "would clobber existing tag"}
                         elsif fast_forward?(walker, old, new_oid)
                           {Fetch::Update::Status::FastForward, nil}
                         elsif force || mapping.force
                           {Fetch::Update::Status::Forced, nil}
                         else
                           {Fetch::Update::Status::Rejected, "non-fast-forward"}
                         end
        updates << Fetch::Update.new(mapping.ref.name, destination, old, new_oid, status, reason)
        next unless status.new? || status.fast_forward? || status.forced?
        message = case status
                  when .new?          then destination.starts_with?("refs/tags/") ? "storing tag" : "storing head"
                  when .fast_forward? then "fast-forward"
                  else                     "forced-update"
                  end
        log = actor.try { |who| References::LogEntry.new(who, "fetch #{label}: #{message}") }
        changes << References::Update.new(destination, new_oid, old, log)
      end
      unless changes.empty?
        change_refs(changes, max_changes: changes.size, max_object_bytes: 268_435_456, check: check)
      end
      updates
    end

    private def fast_forward?(walker : History::RevisionWalker, old : String, new_oid : String) : Bool
      return false unless has_object?(old)
      return false unless object_header(old).type.commit? && object_header(new_oid).type.commit?
      walker.ancestor?(old, new_oid)
    end

    private def prune_tracking_refs(specs : Array(Remote::Refspec), remote_refs : Array(Protocol::RemoteRef),
                                    actor : Signature?, check : Proc(Nil)?) : Array(Fetch::Update)
      names = remote_refs.map(&.name).to_set
      pruned = [] of Fetch::Update
      changes = [] of References::Change
      specs.each do |spec|
        next if spec.negative? || !spec.pattern?
        destination = spec.destination || next
        next if destination.starts_with?("refs/tags/")
        prefix = destination.byte_slice(0, destination.index('*').not_nil!)
        references(prefix).each do |ref|
          next if ref.symbolic?
          source = spec.map_destination(ref.name) || next
          next if names.includes?(source)
          oid = ref.oid || next
          next if changes.any? { |change| change.name == ref.name }
          changes << References::Delete.new(ref.name, oid)
          pruned << Fetch::Update.new(source, ref.name, oid, oid, Fetch::Update::Status::Pruned)
        end
      end
      change_refs(changes, max_changes: changes.size, check: check) unless changes.empty?
      # A dangling remote HEAD symref goes with its target.
      references("refs/remotes/").each do |ref|
        delete_symbolic_ref(ref.name) if ref.symbolic? && ref.oid.nil?
      end
      pruned
    end

    private def write_fetch_head_file(mappings : Array(Fetch::Mapping), url : String) : Nil
      display = url.rstrip('/')
      display = display.byte_slice(0, display.bytesize - 4) if display.bytesize > 4 && display.ends_with?(".git")
      ordered = mappings.select(&.for_merge) + mappings.reject(&.for_merge)
      content = String.build do |io|
        ordered.each do |mapping|
          name = mapping.ref.name
          note = if name.starts_with?("refs/heads/")
                   "branch '#{name.byte_slice(11)}' of "
                 elsif name.starts_with?("refs/tags/")
                   "tag '#{name.byte_slice(10)}' of "
                 elsif name.starts_with?("refs/remotes/")
                   "remote-tracking branch '#{name.byte_slice(13)}' of "
                 elsif name == "HEAD"
                   ""
                 else
                   "'#{name}' of "
                 end
          io << mapping.ref.oid << '\t' << (mapping.for_merge ? "" : "not-for-merge") << '\t' << note << display << '\n'
        end
      end
      path = File.join(@git_dir, "FETCH_HEAD")
      temp = path + ".tmp-#{Random::Secure.hex(6)}"
      File.write(temp, content)
      File.rename(temp, path)
    end

    private def update_shallow(current : Set(String), added : Array(String), removed : Array(String)) : Nil
      return if added.empty? && removed.empty?
      updated = (current + added.to_set) - removed.to_set
      path = File.join(@common, "shallow")
      if updated.empty?
        File.delete?(path)
      else
        temp = path + ".lock"
        File.write(temp, updated.to_a.sort.join('\n') + "\n")
        File.rename(temp, path)
      end
    end
  end
end
