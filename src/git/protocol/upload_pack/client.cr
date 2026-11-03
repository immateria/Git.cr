module Git
  module Protocol
    module UploadPack
      # The result of a v2 fetch beyond the pack itself.
      record FetchOutcome, shallow : Array(String), unshallow : Array(String),
        common : Array(String), rounds : Int32, received_pack : Bool

      # The fetching side of protocol version 2 over one upload-pack
      # connection: ls-refs and fetch with have negotiation.
      class Client
        getter advertisement : Advertisement

        def initialize(@connection : Transport::Connection, advertisement : Advertisement? = nil)
          @advertisement = advertisement || Advertisement.parse(@connection.advertisement)
          raise Violation.new("Git remote does not speak protocol version 2") unless @advertisement.version == 2
        end

        def object_format : ObjectId::Format
          @advertisement.object_format
        end

        def ls_refs(prefixes : Array(String) = [] of String, *, symrefs : Bool = true,
                    peel : Bool = true, unborn : Bool = true) : Array(RemoteRef)
          raise Violation.new("Git remote does not offer ls-refs") unless @advertisement.capability?("ls-refs")
          arguments = [] of String
          arguments << "symrefs" if symrefs
          arguments << "peel" if peel
          arguments << "unborn" if unborn && @advertisement.features("ls-refs").includes?("unborn")
          prefixes.uniq.each { |prefix| arguments << "ref-prefix #{prefix}" }
          refs = [] of RemoteRef
          @connection.request(command("ls-refs", arguments)) do |io|
            lines, kind = PktLine.read_section(io)
            raise Violation.new("Git ls-refs response must end with a flush") unless kind.flush?
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
          raise Violation.new("Git remote does not offer fetch") unless @advertisement.capability?("fetch")
          if depth && !@advertisement.features("fetch").includes?("shallow")
            raise Violation.new("Git remote does not support shallow fetches")
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
                    raise Violation.new("unexpected Git acknowledgment #{text.inspect}")
                  end
                end
                if kind.flush?
                  raise Violation.new("Git server said ready but sent no pack") if ready
                  next
                end
                raise Violation.new("Git server continued without ready") unless ready
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
                  stream = Sideband::Reader.new(io, progress)
                  yield stream
                  # Drain anything the consumer left, through the flush.
                  IO.copy(stream, IO::Memory.new)
                  received = true
                  break
                else
                  raise Violation.new("unexpected Git fetch section #{section.inspect}")
                end
              end
            end
            acknowledged.each do |oid|
              negotiator.try &.acknowledge(oid)
              common << oid unless common.includes?(oid)
            end
            in_vain = acknowledged.empty? ? in_vain + haves.size : 0
            break if received
            raise Violation.new("Git server sent no pack after done") if done
            batch = batch < 1024 ? batch * 2 : batch
          end
          FetchOutcome.new(shallow_found, unshallow_found, common, rounds, received)
        end

        private def read_header(io : IO) : String
          packet = PktLine.read(io).not_nil!
          raise Violation.new("Git response section header missing") unless packet.data?
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
          raise Violation.new("invalid Git ls-refs line") if fields.size < 2
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
end
