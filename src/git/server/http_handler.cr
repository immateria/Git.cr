require "../../git"
require "http/server"
require "compress/gzip"
require "compress/deflate"

module Git
  module Server
    # An HTTP::Handler serving Git's smart HTTP protocol from native
    # upload-pack (protocol v2) and, when enabled, receive-pack. The
    # resolver maps a request path prefix ("/project.git") to a repository
    # or nil; authorization is the resolver's and the application's job.
    #
    #   handler = Git::Server::HTTPHandler.new(receive_pack: true) do |path|
    #     path == "/repo.git" ? Git::Repository.new("/srv/repo.git") : nil
    #   end
    #   HTTP::Server.new([handler]).listen(8080)
    class HTTPHandler
      include ::HTTP::Handler

      def initialize(*, @receive_pack : Bool = false,
                     @receive_options : Protocol::ReceivePack::Options = Protocol::ReceivePack::Options.new,
                     @want_policy : Protocol::UploadPack::WantPolicy = Protocol::UploadPack::WantPolicy::Reachable,
                     &@resolve : String -> Repository?)
      end

      def call(context : ::HTTP::Server::Context) : Nil
        request = context.request
        path = request.path
        if path.ends_with?("/info/refs") && request.method == "GET"
          service = request.query_params["service"]?
          repository = resolve(context, path.rchop("/info/refs")) || return
          serve_advertisement(context, repository, service)
        elsif path.ends_with?("/git-upload-pack") && request.method == "POST"
          repository = resolve(context, path.rchop("/git-upload-pack")) || return
          serve_upload_pack(context, repository)
        elsif path.ends_with?("/git-receive-pack") && request.method == "POST"
          repository = resolve(context, path.rchop("/git-receive-pack")) || return
          serve_receive_pack(context, repository)
        else
          call_next(context)
        end
      end

      private def resolve(context : ::HTTP::Server::Context, prefix : String) : Repository?
        repository = @resolve.call(prefix.empty? ? "/" : prefix)
        unless repository
          context.response.status = ::HTTP::Status::NOT_FOUND
          context.response.print("Repository not found\n")
        end
        repository
      end

      private def version_2?(context : ::HTTP::Server::Context) : Bool
        (context.request.headers["Git-Protocol"]? || "").split(':').includes?("version=2")
      end

      private def serve_advertisement(context : ::HTTP::Server::Context, repository : Repository, service : String?) : Nil
        response = context.response
        response.headers["Cache-Control"] = "no-cache"
        case service
        when "git-upload-pack"
          unless version_2?(context)
            forbidden(context, "This server requires Git protocol version 2 for fetching\n")
            return
          end
          response.content_type = "application/x-git-upload-pack-advertisement"
          Protocol::UploadPack::Server.new(repository, want_policy: @want_policy).advertise(response.output)
        when "git-receive-pack"
          unless @receive_pack
            forbidden(context, "Pushing is disabled\n")
            return
          end
          response.content_type = "application/x-git-receive-pack-advertisement"
          Protocol::PktLine.line(response.output, "# service=git-receive-pack")
          Protocol::PktLine.flush(response.output)
          Protocol::ReceivePack::Server.new(repository, @receive_options).advertise(response.output)
        else
          forbidden(context, "Only the smart HTTP protocol is served\n")
        end
      end

      private def serve_upload_pack(context : ::HTTP::Server::Context, repository : Repository) : Nil
        unless version_2?(context)
          forbidden(context, "This server requires Git protocol version 2 for fetching\n")
          return
        end
        context.response.content_type = "application/x-git-upload-pack-result"
        context.response.headers["Cache-Control"] = "no-cache"
        input = body(context)
        server = Protocol::UploadPack::Server.new(repository, want_policy: @want_policy)
        begin
          while server.handle(input, context.response.output)
          end
        rescue ex : Git::Error
          Protocol::PktLine.write(context.response.output, "ERR #{ex.message}\n")
        end
      end

      private def serve_receive_pack(context : ::HTTP::Server::Context, repository : Repository) : Nil
        unless @receive_pack
          forbidden(context, "Pushing is disabled\n")
          return
        end
        context.response.content_type = "application/x-git-receive-pack-result"
        context.response.headers["Cache-Control"] = "no-cache"
        Protocol::ReceivePack::Server.new(repository, @receive_options).handle(body(context), context.response.output)
      end

      private def body(context : ::HTTP::Server::Context) : IO
        raw = context.request.body || IO::Memory.new
        case context.request.headers["Content-Encoding"]?
        when "gzip"    then Compress::Gzip::Reader.new(raw)
        when "deflate" then Compress::Deflate::Reader.new(raw)
        else                raw
        end
      end

      private def forbidden(context : ::HTTP::Server::Context, message : String) : Nil
        context.response.status = ::HTTP::Status::FORBIDDEN
        context.response.content_type = "text/plain"
        context.response.print(message)
      end
    end
  end
end
