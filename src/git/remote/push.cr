require "set"

module Git
  # `git push`: what each pushed reference did.
  module Push
    # One reference a push looked at.
    record Update, local_ref : String?, remote_ref : String, old_oid : String?,
      new_oid : String?, status : Update::Status, reason : String? = nil do
      enum Status
        # Created or updated on the remote.
        Ok
        Deleted
        UpToDate
        # Refused locally before sending (non-fast-forward, fetch first, ...).
        Rejected
        # Sent, and refused by the remote (its "ng" reason).
        RemoteRejected
      end

      def success? : Bool
        status.ok? || status.deleted? || status.up_to_date?
      end
    end

    # The outcome of a push and how many objects its pack carried.
    record Result, url : String, updates : Array(Update), pack_objects : Int32 do
      def success? : Bool
        updates.all?(&.success?)
      end

      def rejected : Array(Update)
        updates.reject(&.success?)
      end
    end
  end

  class Repository
    # `git push <remote> [<refspec>...]` to a configured remote (by name)
    # or a transport. For a named remote without refspecs, its push
    # refspecs are used, else the current branch is pushed to its upstream
    # (or the same name), as push.default=simple does; transport overrides
    # how it is reached and, with update_tracking, remote-tracking refs
    # follow successful updates. A transport needs explicit refspecs.
    # Non-fast-forward updates are refused unless forced.
    def push(remote : String | Transport = "origin", refspecs : Array(String)? = nil, *,
             transport : Transport? = nil, force : Bool = false,
             atomic : Bool = false, update_tracking : Bool = true,
             actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
             check : Proc(Nil)? = nil) : Push::Result
      if remote.is_a?(Transport)
        raise ArgumentError.new("transport: applies to a named Git remote") if transport
        specs = refspecs || raise ArgumentError.new("Git push to a transport needs refspecs")
        return push_to(remote, specs, url: remote.url, force: force, atomic: atomic,
          progress: progress, check: check)
      end
      configured = remote(remote)
      selected = transport || Transport.for_url(configured.push_url)
      specs = refspecs || begin
        if !configured.push_refspecs.empty?
          configured.push_refspecs.map(&.to_s)
        else
          branch = head_ref_and_oid[0]
          raise Error.new("Git push needs a refspec when HEAD is detached") unless branch && branch.starts_with?("refs/heads/")
          upstream = branch_upstream(branch.byte_slice(11))
          destination = upstream && upstream[0] == remote ? upstream[1] : branch
          ["#{branch}:#{destination}"]
        end
      end
      result = push_to(selected, specs, url: configured.push_url, force: force, atomic: atomic,
        progress: progress, check: check)
      update_tracking_after_push(configured, result, actor) if update_tracking
      result
    end

    protected def push_to(transport : Transport, refspecs : Array(String), *, url : String,
                          force : Bool, atomic : Bool, progress : Proc(String, Nil)?,
                          check : Proc(Nil)?) : Push::Result
      check!
      specs = refspecs.map { |text| Remote::Refspec.parse(text, fetch: false) }
      connection = transport.connect(Transport::Service::ReceivePack, 0)
      begin
        client = Protocol::ReceivePack::Client.new(connection)
        unless client.object_format == @object_format
          raise Error.new("Git remote uses #{client.object_format}, this repository #{@object_format}")
        end
        remote_refs = client.refs
        planned = plan_push(specs, remote_refs, force)
        walker = History::RevisionWalker.new(self, check: check)
        updates = [] of Push::Update
        commands = [] of Push::Update
        planned.each do |local_ref, remote_ref, new_oid, forced|
          old = remote_refs[remote_ref]?
          if new_oid.nil?
            if old.nil?
              updates << Push::Update.new(local_ref, remote_ref, nil, nil, Push::Update::Status::Rejected, "remote ref does not exist")
            elsif !client.capability?("delete-refs")
              updates << Push::Update.new(local_ref, remote_ref, old, nil, Push::Update::Status::Rejected, "remote does not support deleting refs")
            else
              commands << Push::Update.new(local_ref, remote_ref, old, nil, Push::Update::Status::Deleted)
            end
            next
          end
          if old == new_oid
            updates << Push::Update.new(local_ref, remote_ref, old, new_oid, Push::Update::Status::UpToDate)
            next
          end
          reason = nil.as(String?)
          if old && !forced
            if remote_ref.starts_with?("refs/tags/")
              reason = "already exists"
            elsif !has_object?(old)
              reason = "fetch first"
            elsif !(object_header(old).type.commit? && object_header(new_oid).type.commit? && walker.ancestor?(old, new_oid))
              reason = "non-fast-forward"
            end
          end
          if reason
            updates << Push::Update.new(local_ref, remote_ref, old, new_oid, Push::Update::Status::Rejected, reason)
          else
            commands << Push::Update.new(local_ref, remote_ref, old, new_oid, Push::Update::Status::Ok)
          end
        end
        if atomic && updates.any? { |update| update.status.rejected? }
          commands.each { |command| updates << command.copy_with(status: Push::Update::Status::Rejected, reason: "atomic push failed") }
          return Push::Result.new(url, updates, 0)
        end
        return Push::Result.new(url, updates, 0) if commands.empty?

        zero = ObjectId.zero(@object_format)
        wire = commands.map do |command|
          Protocol::ReceivePack::Command.new(command.old_oid || zero, command.new_oid || zero, command.remote_ref)
        end
        objects = 0
        report = client.push(wire, atomic: atomic, progress: progress) do |io|
          tips = commands.compact_map(&.new_oid).uniq
          haves = remote_refs.values.uniq.select { |oid| has_object?(oid) }
          items = reachable_objects(tips, haves, exclude_have_trees: true, check: check)
          bases = [] of History::ReachableObject
          commands.compact_map(&.old_oid).uniq.select { |oid| has_object?(oid) && object_header(oid).type.commit? }.first(4).each do |oid|
            bases.concat(reachable_objects([walker.commit_node(oid).tree], check: check))
          end
          objects = Pack::Builder.new(self, ofs_delta: client.capability?("ofs-delta"), check: check).write(io, items, bases).objects
        end
        raise Protocol::RemoteFailure.new("remote unpack failed: #{report.unpack}") unless report.unpacked?
        commands.each do |command|
          if report.statuses.has_key?(command.remote_ref)
            if failure = report.statuses[command.remote_ref]
              updates << command.copy_with(status: Push::Update::Status::RemoteRejected, reason: failure)
            else
              updates << command
            end
          else
            updates << command.copy_with(status: Push::Update::Status::RemoteRejected, reason: "no report from remote")
          end
        end
        Push::Result.new(url, updates, objects)
      ensure
        connection.close
      end
    end

    # {local ref, remote ref, new oid (nil to delete), forced}
    private def plan_push(specs : Array(Remote::Refspec), remote_refs : Hash(String, String),
                          force : Bool) : Array({String?, String, String?, Bool})
      local = references("refs/")
      local_names = local.map(&.name)
      planned = [] of {String?, String, String?, Bool}
      specs.each do |spec|
        raise Error.new("negative Git push refspecs are not supported") if spec.negative?
        forced = force || spec.force?
        if spec.pattern?
          destination = spec.destination || spec.source
          local.each do |ref|
            next unless spec.source_matches?(ref.name) && (oid = ref.oid)
            mapped = Remote::Refspec.new(spec.source, destination, pattern: true).map_source(ref.name).not_nil!
            planned << {ref.name, mapped, oid, forced}
          end
          next
        end
        source = spec.source
        if source.empty?
          destination = spec.destination || raise Error.new("invalid Git push refspec #{spec}")
          full = destination.starts_with?("refs/") ? destination : (RefName.expand(destination, remote_refs.keys) || "refs/heads/#{destination}")
          planned << {nil, full, nil, forced}
          next
        end
        local_ref, oid = if Remote::Refspec.object_id?(source)
                           {nil, ObjectId.valid!(source, @object_format)}
                         elsif source == "HEAD" || source == "@"
                           {head_ref_and_oid[0], head_ref_and_oid[1] || raise(Error.new("Git HEAD is unborn"))}
                         else
                           full = source.starts_with?("refs/") ? source : RefName.expand(source, local_names)
                           raise Error.new("Git source ref #{source} does not match any") unless full && (resolved = resolve_ref?(full))
                           {full, resolved}
                         end
        destination = spec.destination
        remote_ref = if destination.nil?
                       raise Error.new("Git push of #{source} needs a destination") unless local_ref
                       local_ref
                     elsif destination.starts_with?("refs/")
                       destination
                     elsif found = RefName.expand(destination, remote_refs.keys)
                       found
                     elsif local_ref.try(&.starts_with?("refs/tags/"))
                       "refs/tags/#{destination}"
                     else
                       "refs/heads/#{destination}"
                     end
        raise Error.new("invalid Git push destination #{remote_ref}") unless RefName.valid?(remote_ref)
        planned << {local_ref, remote_ref, oid, forced}
      end
      planned.uniq { |entry| entry[1] }
    end

    private def update_tracking_after_push(remote : Remote, result : Push::Result, actor : Signature?) : Nil
      result.updates.each do |update|
        next unless update.status.ok? || update.status.deleted?
        remote.fetch_refspecs.each do |spec|
          next if spec.negative?
          tracking = spec.map_source(update.remote_ref) || next
          current = resolve_ref?(tracking)
          if new_oid = update.new_oid
            next if current == new_oid
            log = actor.try { |who| References::LogEntry.new(who, "update by push") }
            update_ref(tracking, new_oid, expected_oid: current, log: log, max_object_bytes: 268_435_456)
          elsif current
            delete_ref(tracking, expected_oid: current)
          end
        end
      end
    end
  end
end
