require "http/server"
require "../../src/git/server/http_handler"
require "./git_oracle"

# Loopback smart-HTTP servers for remote specs: upstream Git's
# http-backend (a CGI program) and the native handler.
module GitHTTP
  record Request, method : String, path : String, git_protocol : String?

  # Serve every repository below project_root with `git http-backend`.
  # Pushing is enabled. Yields the base URL.
  def self.backend(project_root : String, log : Array(Request)? = nil, & : String ->) : Nil
    home = File.join(File.dirname(project_root), "http-home")
    Dir.mkdir_p(home)
    server = HTTP::Server.new do |context|
      request = context.request
      log.try &.<< Request.new(request.method, request.path, request.headers["Git-Protocol"]?)
      body = request.body.try(&.gets_to_end) || ""
      environment = {
        "PATH"                => "/usr/bin:/bin",
        "HOME"                => home,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL"   => "/dev/null",
        "GIT_PROJECT_ROOT"    => project_root,
        "GIT_HTTP_EXPORT_ALL" => "1",
        "REMOTE_USER"         => "tester",
        "REMOTE_ADDR"         => "127.0.0.1",
        "REQUEST_METHOD"      => request.method,
        "PATH_INFO"           => request.path,
        "QUERY_STRING"        => request.query || "",
        "CONTENT_TYPE"        => request.headers["Content-Type"]? || "",
        "CONTENT_LENGTH"      => body.bytesize.to_s,
        "GIT_COMMITTER_NAME"  => "HTTP Backend",
        "GIT_COMMITTER_EMAIL" => "backend@example.invalid",
      }
      if encoding = request.headers["Content-Encoding"]?
        environment["HTTP_CONTENT_ENCODING"] = encoding
      end
      if protocol = request.headers["Git-Protocol"]?
        environment["GIT_PROTOCOL"] = protocol
        environment["HTTP_GIT_PROTOCOL"] = protocol
      end
      output = IO::Memory.new
      errors = IO::Memory.new
      Process.run(GitOracle::GIT_BINARY, ["http-backend"], env: environment, clear_env: true,
        input: IO::Memory.new(body), output: output, error: errors)
      raw = output.to_s
      split = raw.index("\r\n\r\n") || raw.index("\n\n") || raise "http-backend sent no headers: #{errors}"
      header_text = raw.byte_slice(0, split)
      separator = raw.byte_slice(split, 4) == "\r\n\r\n" ? 4 : 2
      header_text.each_line do |line|
        name, _, value = line.chomp.partition(':')
        value = value.strip
        if name.downcase == "status"
          context.response.status_code = value.split(' ').first.to_i
        else
          context.response.headers[name] = value
        end
      end
      context.response.write(raw.to_slice[split + separator, raw.bytesize - split - separator])
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      yield "http://127.0.0.1:#{address.port}"
    ensure
      server.close
    end
  end

  # Serve repositories with the native handler. Yields the base URL.
  def self.native(repositories : Hash(String, String), receive_pack : Bool = true,
                  log : Array(Request)? = nil, & : String ->) : Nil
    handler = Git::Server::HTTPHandler.new(receive_pack: receive_pack) do |path|
      repositories[path]?.try { |root| Git::Repository.new(root, max_search_entries: 1_000_000) }
    end
    logger = LogHandler.new(log)
    server = HTTP::Server.new([logger, handler] of HTTP::Handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      yield "http://127.0.0.1:#{address.port}"
    ensure
      server.close
    end
  end

  class LogHandler
    include HTTP::Handler

    def initialize(@log : Array(Request)?)
    end

    def call(context : HTTP::Server::Context) : Nil
      @log.try &.<< Request.new(context.request.method, context.request.path, context.request.headers["Git-Protocol"]?)
      call_next(context)
    end
  end
end
