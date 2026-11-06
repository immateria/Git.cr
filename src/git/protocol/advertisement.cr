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
        else                  raise Violation.new("unsupported Git object format #{@capabilities["object-format"]?}")
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
          raise Violation.new("unexpected Git packet in advertisement") unless packet.data?
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
          if index == 0 && (nul = text.byte_index('\0'))
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
          raise Violation.new("invalid Git ref advertisement line") if name.empty?
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
  end
end
