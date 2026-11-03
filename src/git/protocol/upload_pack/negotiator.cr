require "set"

module Git
  module Protocol
    module UploadPack
      # Client-side have selection: local commits newest first, skipping the
      # ancestors of commits the remote acknowledged (Git's default
      # negotiator, simplified).
      class Negotiator
        COMMON = 1_u8
        QUEUED = 2_u8

        @flags = {} of String => UInt8

        def initialize(@repository : Repository, tips : Array(String), @check : Proc(Nil)? = nil)
          @walker = History::RevisionWalker.new(@repository, check: @check)
          @queue = History::DateQueue.new
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
            @walker.commit_node(oid).parents.each do |parent|
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
            @walker.commit_node(current).parents.each { |parent| stack << parent if flag?(parent, QUEUED) }
          end
        end

        private def enqueue(oid : String) : Nil
          return if flag?(oid, QUEUED)
          mark(oid, QUEUED)
          @queue.push(oid, @walker.commit_node(oid).time)
        end

        private def flag?(oid : String, flag : UInt8) : Bool
          (@flags.fetch(oid, 0_u8) & flag) != 0
        end

        private def mark(oid : String, flag : UInt8) : Nil
          @flags[oid] = @flags.fetch(oid, 0_u8) | flag
        end
      end
    end
  end
end
