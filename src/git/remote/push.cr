require "set"

module Git
  # One reference a push looked at.
  record PushUpdate, local_ref : String?, remote_ref : String, old_oid : String?,
    new_oid : String?, status : PushUpdate::Status, reason : String? = nil do
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

  record PushResult, url : String, updates : Array(PushUpdate), pack_objects : Int32 do
    def success? : Bool
      updates.all?(&.success?)
    end

    def rejected : Array(PushUpdate)
      updates.reject(&.success?)
    end
  end

  class Repository
    # `git push <remote> [<refspec>...]`. Without refspecs the remote's
    # push refspecs are used, else the current branch is pushed to its
    # upstream (or the same name), as push.default=simple does.
    # Non-fast-forward updates are refused unless forced. With
    # update_tracking, remote-tracking refs follow successful updates.
    def push(remote_name : String = "origin", refspecs : Array(String)? = nil, *,
             transport : Transport::Base? = nil, force : Bool = false,
             atomic : Bool = false, update_tracking : Bool = true,
             actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
             check : Proc(Nil)? = nil) : PushResult
      remote = remote(remote_name)
      selected = transport || Transport.for_url(remote.push_url)
      specs = refspecs || begin
        if !remote.push_refspecs.empty?
          remote.push_refspecs.map(&.to_s)
        else
          branch = head[0]
          raise Error.new("Git push needs a refspec when HEAD is detached") unless branch && branch.starts_with?("refs/heads/")
          upstream = branch_upstream(branch.byte_slice(11))
          destination = upstream && upstream[0] == remote_name ? upstream[1] : branch
          ["#{branch}:#{destination}"]
        end
      end
      result = push_to(selected, specs, url: remote.push_url, force: force, atomic: atomic,
        progress: progress, check: check)
      update_tracking_after_push(remote, result, actor) if update_tracking
      result
    end

    # Push to a transport without a configured remote.
    def push_to(transport : Transport::Base, refspecs : Array(String), *, url : String = transport.url,
                force : Bool = false, atomic : Bool = false,
                progress : Proc(String, Nil)? = nil,
                check : Proc(Nil)? = nil) : PushResult
      check!
      specs = refspecs.map { |text| Refspec.parse(text, fetch: false) }
      connection = transport.connect(Transport::Service::ReceivePack, 0)
      begin
        advertisement = Protocol::Advertisement.parse(connection.advertisement)
        raise Protocol::ProtocolError.new("Git remote answered receive-pack with protocol v2") if advertisement.version == 2
        unless advertisement.object_format == @object_format
          raise Error.new("Git remote uses #{advertisement.object_format}, this repository #{@object_format}")
        end
        raise Protocol::ProtocolError.new("Git remote does not offer report-status") unless advertisement.capability?("report-status")
        remote_refs = advertisement.refs.to_h { |ref| {ref.name, ref.oid.not_nil!} }
        zero = Protocol.zero_id(@object_format)
        planned = plan_push(specs, remote_refs, force)
        walker = Reachability::Walker.new(self, check: check)
        updates = [] of PushUpdate
        commands = [] of PushUpdate
        planned.each do |local_ref, remote_ref, new_oid, forced|
          old = remote_refs[remote_ref]?
          if new_oid.nil?
            if old.nil?
              updates << PushUpdate.new(local_ref, remote_ref, nil, nil, PushUpdate::Status::Rejected, "remote ref does not exist")
            elsif !advertisement.capability?("delete-refs")
              updates << PushUpdate.new(local_ref, remote_ref, old, nil, PushUpdate::Status::Rejected, "remote does not support deleting refs")
            else
              commands << PushUpdate.new(local_ref, remote_ref, old, nil, PushUpdate::Status::Deleted)
            end
            next
          end
          if old == new_oid
            updates << PushUpdate.new(local_ref, remote_ref, old, new_oid, PushUpdate::Status::UpToDate)
            next
          end
          reason = nil.as(String?)
          if old && !forced
            if remote_ref.starts_with?("refs/tags/")
              reason = "already exists"
            elsif !has_object?(old)
              reason = "fetch first"
            elsif !(object_header(old)[0] == "commit" && object_header(new_oid)[0] == "commit" && walker.ancestor?(old, new_oid))
              reason = "non-fast-forward"
            end
          end
          if reason
            updates << PushUpdate.new(local_ref, remote_ref, old, new_oid, PushUpdate::Status::Rejected, reason)
          else
            commands << PushUpdate.new(local_ref, remote_ref, old, new_oid, PushUpdate::Status::Ok)
          end
        end
        if atomic && updates.any? { |update| update.status.rejected? }
          commands.each { |command| updates << command.copy_with(status: PushUpdate::Status::Rejected, reason: "atomic push failed") }
          return PushResult.new(url, updates, 0)
        end
        return PushResult.new(url, updates, 0) if commands.empty?
        raise Protocol::ProtocolError.new("Git remote does not support atomic pushes") if atomic && !advertisement.capability?("atomic")

        body = IO::Memory.new
        wanted = ["report-status"]
        wanted << "side-band-64k" if advertisement.capability?("side-band-64k")
        wanted << "atomic" if atomic
        wanted << "quiet" if progress.nil? && advertisement.capability?("quiet")
        wanted << "ofs-delta" if advertisement.capability?("ofs-delta")
        wanted << "object-format=#{@object_format.sha256? ? "sha256" : "sha1"}" if advertisement.capability?("object-format")
        wanted << "agent=#{Protocol::AGENT}"
        commands.each_with_index do |command, index|
          line = "#{command.old_oid || zero} #{command.new_oid || zero} #{command.remote_ref}"
          line += "\0#{wanted.join(' ')}" if index == 0
          Protocol::PktLine.line(body, line)
        end
        Protocol::PktLine.flush(body)
        objects = 0
        if commands.any?(&.new_oid)
          tips = commands.compact_map(&.new_oid).uniq
          haves = remote_refs.values.uniq.select { |oid| has_object?(oid) }
          items = reachable_objects(tips, haves, exclude_have_trees: true, check: check)
          bases = [] of Reachability::Item
          commands.compact_map(&.old_oid).uniq.select { |oid| has_object?(oid) && object_header(oid)[0] == "commit" }.first(4).each do |oid|
            bases.concat(reachable_objects([walker.commit_info(oid).tree], check: check))
          end
          stats = Pack::Builder.new(self, ofs_delta: advertisement.capability?("ofs-delta"), check: check).write(body, items, bases)
          objects = stats.objects
        end
        statuses = {} of String => String?
        unpack = nil.as(String?)
        connection.request(body.to_slice) do |io|
          stream = wanted.includes?("side-band-64k") ? Protocol::SidebandReader.new(io, progress) : io
          loop do
            packet = Protocol::PktLine.read(stream, allow_eof: true)
            break if packet.nil? || packet.flush?
            text = packet.text
            if text.starts_with?("unpack ")
              unpack = text.byte_slice(7)
            elsif text.starts_with?("ok ")
              statuses[text.byte_slice(3)] = nil
            elsif text.starts_with?("ng ")
              name, _, reason = text.byte_slice(3).partition(' ')
              statuses[name] = reason.empty? ? "rejected" : reason
            end
          end
          IO.copy(stream, IO::Memory.new) if stream.is_a?(Protocol::SidebandReader)
        end
        raise Protocol::RemoteError.new("remote unpack failed: #{unpack}") unless unpack == "ok"
        commands.each do |command|
          if statuses.has_key?(command.remote_ref)
            if failure = statuses[command.remote_ref]
              updates << command.copy_with(status: PushUpdate::Status::RemoteRejected, reason: failure)
            else
              updates << command
            end
          else
            updates << command.copy_with(status: PushUpdate::Status::RemoteRejected, reason: "no report from remote")
          end
        end
        PushResult.new(url, updates, objects)
      ensure
        connection.close
      end
    end

    # {local ref, remote ref, new oid (nil to delete), forced}
    private def plan_push(specs : Array(Refspec), remote_refs : Hash(String, String),
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
            mapped = Refspec.new(spec.source, destination, pattern: true).map_source(ref.name).not_nil!
            planned << {ref.name, mapped, oid, forced}
          end
          next
        end
        source = spec.source
        if source.empty?
          destination = spec.destination || raise Error.new("invalid Git push refspec #{spec}")
          full = destination.starts_with?("refs/") ? destination : (Refspec.dwim(destination, remote_refs.keys) || "refs/heads/#{destination}")
          planned << {nil, full, nil, forced}
          next
        end
        local_ref, oid = if Refspec.object_id?(source)
                           {nil, ObjectId.valid!(source, @object_format)}
                         elsif source == "HEAD" || source == "@"
                           {head[0], head[1] || raise(Error.new("Git HEAD is unborn"))}
                         else
                           full = source.starts_with?("refs/") ? source : Refspec.dwim(source, local_names)
                           raise Error.new("Git source ref #{source} does not match any") unless full && (resolved = resolve_ref?(full))
                           {full, resolved}
                         end
        destination = spec.destination
        remote_ref = if destination.nil?
                       raise Error.new("Git push of #{source} needs a destination") unless local_ref
                       local_ref
                     elsif destination.starts_with?("refs/")
                       destination
                     elsif found = Refspec.dwim(destination, remote_refs.keys)
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

    private def update_tracking_after_push(remote : Remote, result : PushResult, actor : Signature?) : Nil
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
