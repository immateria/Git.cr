require "set"

module Git
  module Protocol
    module UploadPack
      # Which objects a client may ask for.
      enum WantPolicy
        # Only ref tips (and the objects their tags peel to).
        Tips
        # Any commit reachable from a ref, as Git's protocol v2 allows.
        Reachable
        # Any object in the repository.
        Any
      end

      # The serving side of protocol version 2 upload-pack: capability
      # advertisement, ls-refs and fetch (with acknowledgments, thin packs,
      # include-tag and shallow clones by depth). Requests are stateless, as
      # over HTTP; a stateful channel simply carries one request after
      # another.
      class Server < Protocol::Server
        def initialize(@repository : Repository, *,
                       @want_policy : WantPolicy = WantPolicy::Reachable,
                       @window : Int32 = 10,
                       @max_object_bytes : Int32 = 268_435_456,
                       @check : Proc(Nil)? = nil)
        end

        def object_format_name : String
          @repository.object_format.sha256? ? "sha256" : "sha1"
        end

        def advertise(io : IO) : Nil
          PktLine.line(io, "version 2")
          PktLine.line(io, "agent=#{AGENT}")
          PktLine.line(io, "ls-refs=unborn")
          PktLine.line(io, "fetch=shallow")
          PktLine.line(io, "server-option")
          PktLine.line(io, "object-format=#{object_format_name}")
          PktLine.flush(io)
          io.flush
        end

        # Serve one command request read from input, writing the response.
        # Returns false at a clean end of input (no further request).
        def handle(input : IO, output : IO) : Bool
          command = nil.as(String?)
          capabilities = [] of String
          packet = PktLine.read(input, allow_eof: true)
          return false unless packet
          return true if packet.flush? # an empty request ends nothing
          loop do
            raise Violation.new("unexpected Git packet before command arguments") unless packet.data?
            text = packet.text
            if text.starts_with?("command=")
              command = text.byte_slice(8)
            else
              capabilities << text
            end
            packet = PktLine.read(input).not_nil!
            break unless packet.data?
          end
          arguments = [] of String
          if packet.delim?
            arguments, _ = PktLine.read_section(input)
          end
          capabilities.each do |capability|
            if capability.starts_with?("object-format=") && capability.byte_slice(14) != object_format_name
              raise Violation.new("Git client object format #{capability.byte_slice(14)} differs from #{object_format_name}")
            end
          end
          case command
          when "ls-refs" then ls_refs(arguments, output)
          when "fetch"   then fetch(arguments, output)
          when nil       then raise Violation.new("Git request has no command")
          else                raise Violation.new("unsupported Git command #{command}")
          end
          output.flush
          true
        end

        private def ls_refs(arguments : Array(String), output : IO) : Nil
          symrefs = arguments.includes?("symrefs")
          peel = arguments.includes?("peel")
          unborn = arguments.includes?("unborn")
          prefixes = arguments.compact_map { |argument| argument.starts_with?("ref-prefix ") ? argument.byte_slice(11) : nil }
          selected = ->(name : String) { prefixes.empty? || prefixes.any? { |prefix| name.starts_with?(prefix) } }
          head = @repository.head
          if selected.call("HEAD")
            if oid = head.oid
              line = "#{oid} HEAD"
              line += " symref-target:#{head.symref_target}" if symrefs && head.symref_target
              line += peeled_suffix(oid) if peel
              PktLine.line(output, line)
            elsif unborn && (target = head.symref_target)
              PktLine.line(output, "unborn HEAD symref-target:#{target}")
            end
          end
          @repository.references("refs/").each do |ref|
            next unless selected.call(ref.name)
            oid = ref.oid || next
            line = "#{oid} #{ref.name}"
            line += " symref-target:#{ref.symref_target}" if symrefs && ref.symref_target
            line += peeled_suffix(oid) if peel
            PktLine.line(output, line)
          end
          PktLine.flush(output)
        end

        private def peeled_suffix(oid : String) : String
          return "" unless @repository.object_header(oid).type.tag?
          _, target, _ = History::RevisionWalker.new(@repository, check: @check).peel(oid)
          " peeled:#{target}"
        end

        private def fetch(arguments : Array(String), output : IO) : Nil
          wants = [] of String
          haves = [] of String
          done = false
          thin = false
          ofs = false
          progress = true
          include_tag = false
          depth = nil.as(Int32?)
          client_shallow = [] of String
          arguments.each do |argument|
            case argument
            when .starts_with?("want ")    then wants << ObjectId.valid!(argument.byte_slice(5), @repository.object_format)
            when .starts_with?("have ")    then haves << ObjectId.valid!(argument.byte_slice(5), @repository.object_format)
            when .starts_with?("shallow ") then client_shallow << ObjectId.valid!(argument.byte_slice(8), @repository.object_format)
            when .starts_with?("deepen ")
              depth = argument.byte_slice(7).to_i? || raise Violation.new("invalid Git deepen argument")
              raise Violation.new("invalid Git deepen depth") if depth < 1
            when "done"        then done = true
            when "thin-pack"   then thin = true
            when "ofs-delta"   then ofs = true
            when "no-progress" then progress = false
            when "include-tag" then include_tag = true
            when .starts_with?("deepen-since "), .starts_with?("deepen-not "), "deepen-relative", .starts_with?("filter ")
              raise Violation.new("unsupported Git fetch argument #{argument.split(' ').first}")
            else
              # Unknown arguments (e.g. wait-for-done, sideband-all) are
              # ignored as Git ignores unadvertised features it does not use.
            end
          end
          raise Violation.new("Git fetch request has no wants") if wants.empty?
          wants.uniq!
          wants.each { |oid| admit_want!(oid) }
          common = haves.select { |oid| @repository.has_object?(oid) && commit?(oid) }.uniq
          walker = History::RevisionWalker.new(@repository, max_object_bytes: @max_object_bytes, check: @check)
          unless done
            PktLine.line(output, "acknowledgments")
            if common.empty?
              PktLine.line(output, "NAK")
            else
              common.each { |oid| PktLine.line(output, "ACK #{oid}") }
            end
            # A shallow request is served at once: its history is cut anyway.
            unless depth || (!common.empty? && ready?(walker, wants, common))
              PktLine.flush(output)
              return
            end
            PktLine.line(output, "ready")
            PktLine.delim(output)
          end
          shallow_lines = [] of String
          boundary = Set(String).new
          if limit = depth
            boundary = shallow_boundary(walker, wants, limit)
            boundary.each { |oid| shallow_lines << "shallow #{oid}" }
            client_shallow.each do |oid|
              shallow_lines << "unshallow #{oid}" if !boundary.includes?(oid) && @repository.has_object?(oid)
            end
            PktLine.line(output, "shallow-info")
            shallow_lines.each { |line| PktLine.line(output, line) }
            PktLine.delim(output)
          end
          PktLine.line(output, "packfile")
          band = Sideband::Writer.new(output)
          items = if depth
                    shallow_objects(walker, wants, boundary)
                  else
                    walker.objects(wants, common)
                  end
          if include_tag
            present = items.map(&.oid).to_set
            @repository.references("refs/tags/").each do |ref|
              oid = ref.oid || next
              next if present.includes?(oid)
              next unless @repository.object_header(oid).type.tag?
              tags, target, _ = walker.peel(oid)
              next unless present.includes?(target)
              tags.each do |tag|
                next if present.includes?(tag)
                present << tag
                items << History::ReachableObject.new(tag, ObjectType::Tag, nil)
              end
            end
          end
          bases = [] of History::ReachableObject
          if thin && !common.empty?
            common.first(4).each do |oid|
              bases.concat(@repository.reachable_objects([walker.commit_node(oid).tree], max_object_bytes: @max_object_bytes, check: @check))
            end
          end
          band.progress("Enumerating objects: #{items.size}, done.\n") if progress
          stats = Pack::Builder.new(@repository, window: @window, ofs_delta: ofs,
            max_object_bytes: @max_object_bytes, check: @check).write(band, items, bases)
          band.finish
          band.progress("Total #{stats.objects} (delta #{stats.deltas})\n") if progress
          PktLine.flush(output)
        end

        # A server-side "ready": each want descends from some common commit.
        private def ready?(walker : History::RevisionWalker, wants : Array(String), common : Array(String)) : Bool
          wants.all? do |want|
            next true unless commit?(want)
            common.first(16).any? { |oid| walker.ancestor?(oid, want) }
          end
        end

        private def commit?(oid : String) : Bool
          @repository.object_header(oid).type.commit?
        end

        private def admit_want!(oid : String) : Nil
          raise RemoteFailure.new("upload-pack: not our ref #{oid}") unless @repository.has_object?(oid)
          return if @want_policy.any?
          tips = [] of String
          @repository.head.oid.try { |head| tips << head }
          @repository.references("refs/").each { |ref| ref.oid.try { |tip| tips << tip } }
          return if tips.includes?(oid)
          walker = History::RevisionWalker.new(@repository, check: @check)
          tips.each do |tip|
            tags, target, kind = walker.peel(tip)
            return if tags.includes?(oid) || target == oid
            next unless @want_policy.reachable? && kind == "commit" && commit?(oid)
            return if walker.ancestor?(oid, target)
          end
          raise RemoteFailure.new("upload-pack: not our ref #{oid}")
        end

        # Commits at the depth limit: their parents are not sent.
        private def shallow_boundary(walker : History::RevisionWalker, wants : Array(String), depth : Int32) : Set(String)
          boundary = Set(String).new
          distance = {} of String => Int32
          queue = Deque(String).new
          wants.each do |want|
            _, target, kind = walker.peel(want)
            next unless kind == "commit"
            next if distance.has_key?(target)
            distance[target] = 1
            queue << target
          end
          until queue.empty?
            oid = queue.shift
            level = distance[oid]
            parents = walker.commit_node(oid).parents
            if level >= depth
              boundary << oid unless parents.empty?
              next
            end
            parents.each do |parent|
              next if distance.has_key?(parent)
              distance[parent] = level + 1
              queue << parent
            end
          end
          boundary
        end

        # Objects of commits within depth of the wants: the boundary's
        # parents are treated as absent.
        private def shallow_objects(walker : History::RevisionWalker, wants : Array(String),
                                    boundary : Set(String)) : Array(History::ReachableObject)
          commits = [] of String
          seen = Set(String).new
          stack = [] of String
          pending = [] of History::ReachableObject
          wants.each do |want|
            tags, target, kind = walker.peel(want)
            tags.each { |tag| pending << History::ReachableObject.new(tag, ObjectType::Tag, nil) }
            if kind == "commit"
              stack << target
            else
              pending.concat(@repository.reachable_objects([target], max_object_bytes: @max_object_bytes, check: @check))
            end
          end
          until stack.empty?
            oid = stack.pop
            next unless seen.add?(oid)
            commits << oid
            next if boundary.includes?(oid)
            walker.commit_node(oid).parents.reverse_each { |parent| stack << parent }
          end
          items = commits.map { |oid| History::ReachableObject.new(oid, ObjectType::Commit, nil) }
          trees = @repository.reachable_objects(commits.map { |oid| walker.commit_node(oid).tree },
            max_object_bytes: @max_object_bytes, check: @check)
          present = Set(String).new
          (items + pending + trees).select { |item| present.add?(item.oid) }
        end
      end
    end
  end
end
