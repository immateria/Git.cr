require "http/client"
require "uri"
require "base64"
require "socket"
require "openssl"

module Git
  abstract class Transport
    # Git's smart HTTP protocol (stateless RPC). Nothing ambient is used:
    # credentials come from the supplied provider, TLS from the supplied
    # context and a proxy only when one is named.
    class HTTP < Transport
      USER_AGENT = "git/#{Protocol::AGENT}"

      getter url : String
      getter credential : Credential?

      def initialize(url : String, *,
                     @credentials : CredentialProvider? = nil,
                     @credential : Credential? = nil,
                     @headers : ::HTTP::Headers = ::HTTP::Headers.new,
                     @tls : OpenSSL::SSL::Context::Client? = nil,
                     @proxy : String? = nil,
                     @user_agent : String = USER_AGENT,
                     @connect_timeout : Time::Span = 30.seconds,
                     @read_timeout : Time::Span = 300.seconds,
                     @max_redirects : Int32 = 5,
                     @max_advertisement_bytes : Int32 = 64 * 1024 * 1024)
        uri = URI.parse(url)
        raise ArgumentError.new("Git HTTP transport needs an http or https URL") unless {"http", "https"}.includes?(uri.scheme)
        if (user = uri.user) && @credential.nil?
          @credential = Credential.new(URI.decode_www_form(user), URI.decode_www_form(uri.password || ""))
        end
        uri.user = nil
        uri.password = nil
        @url = uri.to_s.rchop('/')
      end

      def connect(service : Service, protocol_version : Int32 = 2) : Transport::Connection
        Connection.new(self, service, protocol_version)
      end

      # One HTTP exchange with authentication retry and redirects for GET.
      # :nodoc:
      def exchange(method : String, url : String, headers : ::HTTP::Headers, body : Bytes?,
                   & : ::HTTP::Client::Response, String ->) : Nil
        attempt = 0
        redirects = 0
        current = url
        loop do
          request_headers = @headers.dup
          headers.each { |key, values| request_headers[key] = values }
          request_headers["User-Agent"] = @user_agent
          # Credentials go only to the origin they were given for, never to
          # a host a redirect points at.
          if (credential = @credential) && same_origin?(current, @url)
            request_headers["Authorization"] = "Basic #{Base64.strict_encode("#{credential.username}:#{credential.password}")}"
          end
          retry = false
          redirect = nil.as(String?)
          with_client(current) do |client, path|
            request = ::HTTP::Request.new(method, path, request_headers, body)
            client.exec(request) do |response|
              case response.status_code
              when 401
                raise AuthenticationFailure.new("Git HTTP authentication required by #{current}, a different origin than #{@url}") unless same_origin?(current, @url)
                attempt += 1
                provider = @credentials
                found = provider.try &.call(current, attempt)
                raise AuthenticationFailure.new("Git HTTP authentication failed for #{current}") unless found
                @credential = found
                retry = true
              when 301, 302, 303, 307, 308
                raise ConnectionFailure.new("Git HTTP redirect limit exceeded") if (redirects += 1) > @max_redirects
                location = response.headers["Location"]? || raise ConnectionFailure.new("Git HTTP redirect without a location")
                raise ConnectionFailure.new("Git HTTP redirect of a #{method} request") unless method == "GET"
                redirect = URI.parse(current).resolve(location).to_s
              when 200
                yield response, current
              else
                raise ConnectionFailure.new("Git HTTP #{method} #{current} failed: #{response.status_code} #{response.status_message}")
              end
            end
          end
          if target = redirect
            current = target
            next
          end
          break unless retry
        end
      end

      private def same_origin?(left : String, right : String) : Bool
        a = URI.parse(left)
        b = URI.parse(right)
        a.scheme == b.scheme && a.host.try(&.downcase) == b.host.try(&.downcase) &&
          (a.port || (a.scheme == "https" ? 443 : 80)) == (b.port || (b.scheme == "https" ? 443 : 80))
      end

      private def with_client(url : String, & : ::HTTP::Client, String ->) : Nil
        uri = URI.parse(url)
        host = uri.host || raise ArgumentError.new("Git HTTP URL has no host")
        https = uri.scheme == "https"
        port = uri.port || (https ? 443 : 80)
        path = uri.request_target
        client = if proxy = @proxy
                   socket = tunnel(URI.parse(proxy), host, port)
                   io = if https
                          OpenSSL::SSL::Socket::Client.new(socket, context: @tls || OpenSSL::SSL::Context::Client.new,
                            sync_close: true, hostname: host)
                        else
                          socket
                        end
                   ::HTTP::Client.new(io, host, port)
                 else
                   tls = https ? (@tls || OpenSSL::SSL::Context::Client.new) : nil
                   ::HTTP::Client.new(host, port, tls: tls).tap do |plain|
                     plain.connect_timeout = @connect_timeout
                   end
                 end
        client.read_timeout = @read_timeout
        begin
          yield client, path
        ensure
          client.close
        end
      rescue ex : Socket::Error | IO::TimeoutError | OpenSSL::Error
        raise ConnectionFailure.new("Git HTTP connection to #{url} failed: #{ex.class}: #{ex.message}")
      end

      # Open an HTTP CONNECT tunnel through the proxy.
      private def tunnel(proxy : URI, host : String, port : Int32) : TCPSocket
        proxy_host = proxy.host || raise ArgumentError.new("Git HTTP proxy has no host")
        socket = TCPSocket.new(proxy_host, proxy.port || 80, connect_timeout: @connect_timeout)
        socket.read_timeout = @read_timeout
        socket << "CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n"
        if user = proxy.user
          token = Base64.strict_encode("#{URI.decode_www_form(user)}:#{URI.decode_www_form(proxy.password || "")}")
          socket << "Proxy-Authorization: Basic #{token}\r\n"
        end
        socket << "\r\n"
        socket.flush
        status = socket.gets || raise ConnectionFailure.new("Git HTTP proxy closed the connection")
        code = status.split(' ')[1]?.try(&.to_i?)
        while (line = socket.gets) && !line.chomp.empty?
        end
        raise ConnectionFailure.new("Git HTTP proxy refused the tunnel: #{status.strip}") unless code == 200
        socket
      end

      # One stateless conversation: the advertisement GET and then a POST
      # per request.
      class Connection < Transport::Connection
        getter base_url : String
        @advertisement : Bytes

        def initialize(@transport : HTTP, @service : Service, @protocol_version : Int32)
          @base_url = @transport.url
          headers = ::HTTP::Headers{"Accept" => "*/*", "Pragma" => "no-cache"}
          headers["Git-Protocol"] = "version=#{@protocol_version}" if @protocol_version > 0
          raw = Bytes.empty
          @transport.exchange("GET", "#{@base_url}/info/refs?service=#{@service.git_name}", headers, nil) do |response, final_url|
            type = response.content_type || ""
            unless type == "application/x-#{@service.git_name}-advertisement"
              raise Protocol::Violation.new("Git server at #{final_url} does not speak the smart HTTP protocol (#{type.inspect})")
            end
            suffix = "/info/refs?service=#{@service.git_name}"
            @base_url = final_url.ends_with?(suffix) ? final_url.byte_slice(0, final_url.bytesize - suffix.bytesize) : @base_url
            buffer = IO::Memory.new
            IO.copy(response.body_io, buffer, 64 * 1024 * 1024)
            raw = buffer.to_slice
          end
          @advertisement = Transport.strip_service_preamble(raw, @service)
        end

        def advertisement : Bytes
          @advertisement
        end

        def stateless? : Bool
          true
        end

        def request(body : Bytes, & : IO ->) : Nil
          headers = ::HTTP::Headers{
            "Content-Type" => "application/x-#{@service.git_name}-request",
            "Accept"       => "application/x-#{@service.git_name}-result",
          }
          headers["Git-Protocol"] = "version=#{@protocol_version}" if @protocol_version > 0
          @transport.exchange("POST", "#{@base_url}/#{@service.git_name}", headers, body) do |response, _|
            type = response.content_type || ""
            unless type == "application/x-#{@service.git_name}-result"
              raise Protocol::Violation.new("Git server answered #{@service.git_name} with #{type.inspect}")
            end
            yield response.body_io
          end
        end
      end
    end
  end
end
