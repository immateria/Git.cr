require "set"

module Git
  module Protocol
    # A reference as a remote advertises it.
    record RemoteRef, name : String, oid : String?, symref_target : String? = nil, peeled : String? = nil do
      def unborn? : Bool
        oid.nil?
      end
    end

    # A parsed upload-pack or receive-pack advertisement.
    class Advertisement
      getter version : Int32
      # v2 capability lines (key => value), or v0/v1 capabilities after the
      # first ref's NUL.
      getter capabilities : Hash(String, String?)
      # v0/v1 only: the advertised refs (v2 lists refs with ls-refs).
      getter refs : Array(RemoteRef)

      def initialize(@version, @capabilities, @refs)
      end

      def capability?(name : String) : Bool
        @capabilities.has_key?(name)
      end

      def object_format : ObjectId::Format
        case @capabilities["object-format"]?
        when nil, "sha1" then ObjectId::Format::SHA1
        when "sha256"    then ObjectId::Format::SHA256
        else                  raise ProtocolError.new("unsupported Git object format #{@capabilities["object-format"]?}")
        end
      end

      # v2 features of a command, e.g. features("fetch") => ["shallow"].
      def features(command : String) : Array(String)
        (@capabilities[command]? || "").split(' ', remove_empty: true)
      end

      def self.parse(raw : Bytes) : Advertisement
        io = IO::Memory.new(raw)
        lines = [] of Bytes
        loop do
          packet = PktLine.read(io, allow_eof: true) || break
          break if packet.flush?
          raise ProtocolError.new("unexpected Git packet in advertisement") unless packet.data?
          lines << packet.data
        end
        first = lines.first?.try { |line| String.new(line).chomp }
        if first == "version 2"
          capabilities = {} of String => String?
          lines[1..].each do |line|
            text = String.new(line).chomp
            key, _, value = text.partition('=')
            capabilities[key] = value.empty? && !text.includes?('=') ? nil : value
          end
          return new(2, capabilities, [] of RemoteRef)
        end
        version = 0
        if first == "version 1"
          version = 1
          lines.shift
        end
        capabilities = {} of String => String?
        refs = [] of RemoteRef
        symrefs = {} of String => String
        lines.each_with_index do |line, index|
          text = String.new(line)
          text = text.chomp
          if index == 0 && (nul = text.index('\0'))
            text.byte_slice(nul + 1).split(' ', remove_empty: true).each do |capability|
              key, _, value = capability.partition('=')
              if key == "symref"
                source, _, target = value.partition(':')
                symrefs[source] = target
              else
                capabilities[key] = capability.includes?('=') ? value : nil
              end
            end
            text = text.byte_slice(0, nul)
          end
          oid, _, name = text.partition(' ')
          raise ProtocolError.new("invalid Git ref advertisement line") if name.empty?
          next unless name == "HEAD" || name == "capabilities^{}" || name.ends_with?("^{}") || (name.starts_with?("refs/") && RefName.valid?(name))
          if name.ends_with?("^{}")
            base = name.byte_slice(0, name.bytesize - 3)
            if previous = refs.index { |ref| ref.name == base }
              refs[previous] = refs[previous].copy_with(peeled: oid)
            end
            next
          end
          # An empty repository advertises "capabilities^{}" with a zero ID.
          next if name == "capabilities^{}"
          refs << RemoteRef.new(name, oid)
        end
        refs = refs.map { |ref| (target = symrefs[ref.name]?) ? ref.copy_with(symref_target: target) : ref }
        new(version, capabilities, refs)
      end
    end

    # Client-side have selection: local commits newest first, skipping the
    # ancestors of commits the remote acknowledged (Git's default
    # negotiator, simplified).
    class Negotiator
      COMMON = 1_u8
      QUEUED = 2_u8

      @flags = {} of String => UInt8

      def initialize(@repository : Repository, tips : Array(String), @check : Proc(Nil)? = nil)
        @walker = Reachability::Walker.new(@repository, check: @check)
        @queue = Reachability::DateQueue.new
        tips.each do |tip|
          next unless @repository.has_object?(tip)
          _, target, kind = begin
            @walker.peel(tip)
          rescue Git::Error
            next
          end
          next unless kind == "commit"
          enqueue(target)
        end
      end

      def next_haves(count : Int32) : Array(String)
        haves = [] of String
        until haves.size >= count || @queue.empty?
          @check.try &.call
          oid = @queue.pop
          common = flag?(oid, COMMON)
          haves << oid unless common
          @walker.commit_info(oid).parents.each do |parent|
            next unless @repository.has_object?(parent)
            mark(parent, COMMON) if common
            enqueue(parent)
          end
        end
        haves
      end

      # The remote has oid; neither it nor its ancestors are worth sending.
      def acknowledge(oid : String) : Nil
        stack = [oid]
        until stack.empty?
          current = stack.pop
          next if flag?(current, COMMON)
          mark(current, COMMON)
          # Only already-queued ancestors need flags now; the rest inherit
          # COMMON when popped.
          next unless flag?(current, QUEUED)
          @walker.commit_info(current).parents.each { |parent| stack << parent if flag?(parent, QUEUED) }
        end
      end

      private def enqueue(oid : String) : Nil
        return if flag?(oid, QUEUED)
        mark(oid, QUEUED)
        @queue.push(oid, @walker.commit_info(oid).time)
      end

      private def flag?(oid : String, flag : UInt8) : Bool
        (@flags.fetch(oid, 0_u8) & flag) != 0
      end

      private def mark(oid : String, flag : UInt8) : Nil
        @flags[oid] = @flags.fetch(oid, 0_u8) | flag
      end
    end

    # The result of a v2 fetch beyond the pack itself.
    record FetchOutcome, shallow : Array(String), unshallow : Array(String),
      common : Array(String), rounds : Int32, received_pack : Bool

    # Protocol version 2 client over one upload-pack connection.
    class V2Client
      getter advertisement : Advertisement

      def initialize(@connection : Transport::Connection, advertisement : Advertisement? = nil)
        @advertisement = advertisement || Advertisement.parse(@connection.advertisement)
        raise ProtocolError.new("Git remote does not speak protocol version 2") unless @advertisement.version == 2
      end

      def object_format : ObjectId::Format
        @advertisement.object_format
      end

      def ls_refs(prefixes : Array(String) = [] of String, *, symrefs : Bool = true,
                  peel : Bool = true, unborn : Bool = true) : Array(RemoteRef)
        raise ProtocolError.new("Git remote does not offer ls-refs") unless @advertisement.capability?("ls-refs")
        arguments = [] of String
        arguments << "symrefs" if symrefs
        arguments << "peel" if peel
        arguments << "unborn" if unborn && @advertisement.features("ls-refs").includes?("unborn")
        prefixes.uniq.each { |prefix| arguments << "ref-prefix #{prefix}" }
        refs = [] of RemoteRef
        @connection.request(command("ls-refs", arguments)) do |io|
          lines, kind = PktLine.read_section(io)
          raise ProtocolError.new("Git ls-refs response must end with a flush") unless kind.flush?
          lines.each do |line|
            ref = parse_ls_ref(line)
            # A server cannot make the client write outside refs/.
            refs << ref if ref.name == "HEAD" || (ref.name.starts_with?("refs/") && RefName.valid?(ref.name))
          end
        end
        refs
      end

      # Negotiate and receive one pack for wants. The block receives the
      # pack stream (side-band data); it must read the whole pack.
      def fetch(wants : Array(String), negotiator : Negotiator?, *,
                thin_pack : Bool = true, include_tag : Bool = true,
                depth : Int32? = nil, shallow : Array(String) = [] of String,
                progress : Proc(String, Nil)? = nil, max_rounds : Int32 = 64,
                max_in_vain : Int32 = 256,
                & : IO ->) : FetchOutcome
        raise ProtocolError.new("Git remote does not offer fetch") unless @advertisement.capability?("fetch")
        if depth && !@advertisement.features("fetch").includes?("shallow")
          raise ProtocolError.new("Git remote does not support shallow fetches")
        end
        common = [] of String
        in_vain = 0
        batch = 16
        rounds = 0
        shallow_found = [] of String
        unshallow_found = [] of String
        received = false
        loop do
          rounds += 1
          haves = negotiator ? negotiator.next_haves(batch) : [] of String
          done = haves.empty? || rounds >= max_rounds || (!common.empty? && in_vain >= max_in_vain)
          arguments = [] of String
          arguments << "thin-pack" if thin_pack
          arguments << "ofs-delta"
          arguments << "include-tag" if include_tag
          arguments << "no-progress" unless progress
          wants.uniq.each { |oid| arguments << "want #{oid}" }
          shallow.each { |oid| arguments << "shallow #{oid}" }
          arguments << "deepen #{depth}" if depth
          common.each { |oid| arguments << "have #{oid}" }
          haves.each { |oid| arguments << "have #{oid}" }
          arguments << "done" if done
          acknowledged = [] of String
          @connection.request(command("fetch", arguments)) do |io|
            section = read_header(io)
            if section == "acknowledgments"
              ready = false
              kind = PktLine::Kind::Flush
              loop do
                packet = PktLine.read(io).not_nil!
                unless packet.data?
                  kind = packet.kind
                  break
                end
                text = packet.text
                if text.starts_with?("ACK ")
                  acknowledged << ObjectId.valid!(text.byte_slice(4), object_format)
                elsif text == "ready"
                  ready = true
                elsif text != "NAK"
                  raise ProtocolError.new("unexpected Git acknowledgment #{text.inspect}")
                end
              end
              if kind.flush?
                raise ProtocolError.new("Git server said ready but sent no pack") if ready
                next
              end
              raise ProtocolError.new("Git server continued without ready") unless ready
              section = read_header(io)
            end
            loop do
              case section
              when "shallow-info"
                lines, _ = PktLine.read_section(io)
                lines.each do |line|
                  if line.starts_with?("shallow ")
                    shallow_found << ObjectId.valid!(line.byte_slice(8), object_format)
                  elsif line.starts_with?("unshallow ")
                    unshallow_found << ObjectId.valid!(line.byte_slice(10), object_format)
                  end
                end
                section = read_header(io)
              when "wanted-refs", "packfile-uris"
                PktLine.read_section(io)
                section = read_header(io)
              when "packfile"
                stream = SidebandReader.new(io, progress)
                yield stream
                # Drain anything the consumer left, through the flush.
                IO.copy(stream, IO::Memory.new)
                received = true
                break
              else
                raise ProtocolError.new("unexpected Git fetch section #{section.inspect}")
              end
            end
          end
          acknowledged.each do |oid|
            negotiator.try &.acknowledge(oid)
            common << oid unless common.includes?(oid)
          end
          in_vain = acknowledged.empty? ? in_vain + haves.size : 0
          break if received
          raise ProtocolError.new("Git server sent no pack after done") if done
          batch = batch < 1024 ? batch * 2 : batch
        end
        FetchOutcome.new(shallow_found, unshallow_found, common, rounds, received)
      end

      private def read_header(io : IO) : String
        packet = PktLine.read(io).not_nil!
        raise ProtocolError.new("Git response section header missing") unless packet.data?
        packet.text
      end

      private def command(name : String, arguments : Array(String)) : Bytes
        io = IO::Memory.new
        PktLine.line(io, "command=#{name}")
        PktLine.line(io, "agent=#{AGENT}")
        if format = @advertisement.capabilities["object-format"]?
          PktLine.line(io, "object-format=#{format}")
        end
        PktLine.delim(io)
        arguments.each { |argument| PktLine.line(io, argument) }
        PktLine.flush(io)
        io.to_slice
      end

      private def parse_ls_ref(line : String) : RemoteRef
        fields = line.split(' ')
        raise ProtocolError.new("invalid Git ls-refs line") if fields.size < 2
        oid = fields[0] == "unborn" ? nil : ObjectId.valid!(fields[0], object_format)
        target = nil.as(String?)
        peeled = nil.as(String?)
        fields[2..].each do |attribute|
          if attribute.starts_with?("symref-target:")
            target = attribute.byte_slice(14)
          elsif attribute.starts_with?("peeled:")
            peeled = ObjectId.valid!(attribute.byte_slice(7), object_format)
          end
        end
        RemoteRef.new(fields[1], oid, target, peeled)
      end
    end
  end
end
