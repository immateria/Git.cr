require "set"

module Git
  module Protocol
    ZERO_ID_SHA1   = "0" * 40
    ZERO_ID_SHA256 = "0" * 64

    def self.zero_id(format : ObjectId::Format) : String
      format.sha256? ? ZERO_ID_SHA256 : ZERO_ID_SHA1
    end

    # The serving side of receive-pack (protocol version 0/1): reference
    # advertisement, update commands, the pack, and report-status, with
    # side-band-64k, atomic and delete-refs. No hooks run.
    class ReceivePack
      record Options, deny_current_branch : Bool = true, deny_non_fast_forwards : Bool = false,
        deny_deletes : Bool = false, actor : Signature? = nil, check : Proc(Nil)? = nil

      record Command, old_oid : String, new_oid : String, name : String

      CAPABILITIES = ["report-status", "delete-refs", "side-band-64k", "quiet", "atomic", "ofs-delta"]

      def initialize(@repository : Repository, @options : Options = Options.new)
      end

      def advertise(io : IO) : Nil
        format = @repository.object_format.sha256? ? "sha256" : "sha1"
        capabilities = (CAPABILITIES + ["object-format=#{format}", "agent=#{AGENT}"]).join(' ')
        refs = @repository.references("refs/").reject(&.symbolic?)
        if refs.empty?
          PktLine.line(io, "#{Protocol.zero_id(@repository.object_format)} capabilities^{}\0#{capabilities}")
        else
          refs.each_with_index do |ref, index|
            line = "#{ref.oid} #{ref.name}"
            line += "\0#{capabilities}" if index == 0
            PktLine.line(io, line)
          end
        end
        PktLine.flush(io)
        io.flush
      end

      def handle(input : IO, output : IO) : Nil
        commands = [] of Command
        capabilities = Set(String).new
        loop do
          packet = PktLine.read(input, allow_eof: true)
          return unless packet
          break if packet.flush?
          raise ProtocolError.new("unexpected Git packet in push commands") unless packet.data?
          text = String.new(packet.data).chomp
          if nul = text.index('\0')
            text.byte_slice(nul + 1).split(' ', remove_empty: true).each { |capability| capabilities << capability }
            text = text.byte_slice(0, nul)
          end
          fields = text.split(' ')
          raise ProtocolError.new("invalid Git push command") unless fields.size == 3
          commands << Command.new(ObjectId.valid!(fields[0], @repository.object_format),
            ObjectId.valid!(fields[1], @repository.object_format), fields[2])
        end
        return if commands.empty?
        zero = Protocol.zero_id(@repository.object_format)
        unpack_error = nil.as(String?)
        received = nil.as(Pack::Received?)
        if commands.any? { |command| command.new_oid != zero }
          begin
            received = @repository.receive_pack(input, keep: "receive-pack #{Process.pid}", check: @options.check)
          rescue ex : Git::Error
            unpack_error = ex.message || ex.class.name
          end
        end
        results = if unpack_error
                    commands.map { |command| {command, "unpacker error".as(String?)} }
                  else
                    apply(commands, capabilities.includes?("atomic"))
                  end
        received.try { |pack| @repository.release_pack_keep(pack) }
        report = IO::Memory.new
        PktLine.line(report, unpack_error ? "unpack #{unpack_error}" : "unpack ok")
        results.each do |command, error|
          PktLine.line(report, error ? "ng #{command.name} #{error}" : "ok #{command.name}")
        end
        PktLine.flush(report)
        if capabilities.includes?("side-band-64k")
          band = SidebandWriter.new(output)
          band.write(report.to_slice)
          band.finish
          PktLine.flush(output)
        elsif capabilities.includes?("report-status")
          output.write(report.to_slice)
        end
        output.flush
      end

      # Validate every command, then apply. Atomic pushes are all or none.
      private def apply(commands : Array(Command), atomic : Bool) : Array({Command, String?})
        zero = Protocol.zero_id(@repository.object_format)
        current_branch = @repository.bare? ? nil : @repository.head[0]
        walker = Reachability::Walker.new(@repository, check: @options.check)
        checked = commands.map do |command|
          error = nil.as(String?)
          begin
            raise Error.new("funny refname") unless command.name.starts_with?("refs/") && RefName.valid?(command.name)
            current = @repository.resolve_ref?(command.name)
            if command.new_oid == zero
              error = "deletion prohibited" if @options.deny_deletes
              error ||= "deletion of the current branch prohibited" if command.name == current_branch && @options.deny_current_branch
              error ||= "no such ref" unless current
            else
              error = "branch is currently checked out" if command.name == current_branch && @options.deny_current_branch
              error ||= "missing necessary objects" unless @repository.has_object?(command.new_oid)
              if error.nil? && current && @options.deny_non_fast_forwards &&
                 !(@repository.object_header(current)[0] == "commit" && walker.ancestor?(current, command.new_oid))
                error = "non-fast-forward"
              end
            end
            expected = command.old_oid == zero ? nil : command.old_oid
            error ||= "failed to lock" unless current == expected
          rescue ex : Git::Error
            error = ex.message || "invalid"
          end
          {command, error}
        end
        if error = connectivity_error(checked.select { |_, failure| failure.nil? }.map(&.[0]))
          return checked.map { |command, failure| {command, (failure || error).as(String?)} }
        end
        if atomic && checked.any? { |_, failure| failure }
          return checked.map { |command, failure| {command, (failure || "atomic push failure").as(String?)} }
        end
        accepted = checked.select { |_, failure| failure.nil? }.map(&.[0])
        changes = accepted.map do |command|
          log = @options.actor.try { |actor| References::LogEntry.new(actor, "push") }
          if command.new_oid == zero
            References::Delete.new(command.name, command.old_oid).as(References::Change)
          else
            References::Update.new(command.name, command.new_oid, command.old_oid == zero ? nil : command.old_oid, log).as(References::Change)
          end
        end
        unless changes.empty?
          begin
            @repository.change_refs(changes, max_changes: changes.size, max_object_bytes: 268_435_456, check: @options.check)
          rescue ex : Git::Error
            failure = ex.message || "failed to update ref"
            return checked.map { |command, error| {command, (error || failure).as(String?)} }
          end
        end
        checked
      end

      private def connectivity_error(commands : Array(Command)) : String?
        zero = Protocol.zero_id(@repository.object_format)
        tips = commands.map(&.new_oid).reject { |oid| oid == zero }.uniq
        return nil if tips.empty?
        existing = @repository.references("refs/").compact_map(&.oid).select { |oid| @repository.has_object?(oid) }
        items = Reachability::Walker.new(@repository, check: @options.check).objects(tips, existing)
        items.each do |item|
          return "missing necessary objects" unless item.type != "blob" || @repository.has_object?(item.oid)
        end
        nil
      rescue ex : Git::Error
        "missing necessary objects"
      end
    end
  end
end
