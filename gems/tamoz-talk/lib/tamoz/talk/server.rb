# frozen_string_literal: true

require 'digest'
require 'json'
require 'openssl'
require 'socket'

module Tamoz
  module Talk
    # The talk page's HTTP edge: static assets for anyone on an allowed host, the API for the token holder only.
    class Server
      MAX_CONNECTIONS = 16
      ASSETS = File.expand_path('../../../assets', __dir__)
      STATIC = {
        '/' => 'index.html', '/talk.js' => 'talk.js', '/talk.css' => 'talk.css',
        '/capture-worklet.js' => 'capture-worklet.js', '/vad.mjs' => 'vad.mjs', '/wav.mjs' => 'wav.mjs',
        '/retry.mjs' => 'retry.mjs', '/pairing.mjs' => 'pairing.mjs', '/render.mjs' => 'render.mjs',
        '/gate.mjs' => 'gate.mjs'
      }.freeze
      TYPES = { '.html' => 'text/html; charset=utf-8', '.js' => 'text/javascript; charset=utf-8',
                '.mjs' => 'text/javascript; charset=utf-8', '.css' => 'text/css; charset=utf-8' }.freeze
      CSP = "default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self' blob:; connect-src 'self'; " \
            "img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      LIMITS = { '/v1/messages' => 8192, '/v1/utterances' => 2_000_000, '/v1/decisions' => 1024 }.freeze
      MAX_EVENTS_WAIT_S = 25
      API_HEADERS = { 'Cache-Control' => 'no-store' }.freeze
      LINGER_S = 0.5
      LINGER_BYTES = 4_000_000

      attr_reader :port

      def initialize(hub:, host:, port:, token_digest:, allow_hosts: [], trace: false, deadlines: {})
        @hub = hub
        @head_deadline_s = deadlines.fetch(:head, Http::HEAD_DEADLINE_S)
        @body_deadline_s = deadlines.fetch(:body, Http::BODY_DEADLINE_S)
        @write_deadline_s = deadlines.fetch(:write, Http::WRITE_DEADLINE_S)
        @host = host
        @port = port
        @token_digest = token_digest
        @assets = STATIC.transform_values { |name| File.binread(File.join(ASSETS, name)) }
        @allow_hosts = allow_hosts.map(&:downcase)
        @trace = trace
        @open = 0
        @mutex = Mutex.new
      end

      def start
        @listener = TCPServer.new(@host, @port)
        @port = @listener.addr[1]
        @thread = Thread.new { accept_loop }
        self
      end

      def alive? = @thread&.alive? || false

      def stop
        @stopping = true
        @listener&.close
        @thread&.join(2)
      end

      private

      def accept_loop
        until @stopping
          begin
            socket = @listener.accept
          rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS
            sleep 0.05
            next
          rescue IOError, SystemCallError => e
            break if @stopping

            warn "tamoz: talk server accept failed (#{e.class})"
            next
          end
          next refuse_busy(socket) unless reserve

          Thread.new(socket) { |client| serve(client) }
        end
      end

      def serve(socket)
        request, early = Http.read_head(socket, deadline: Http.monotonic + @head_deadline_s)
        respond(socket, request, early)
      rescue Http::Refused => e
        reply(socket, e.status, e.message)
      rescue EOFError, IOError, SystemCallError
        nil
      rescue StandardError => e
        warn "tamoz: talk server request failed (#{e.class})"
        reply(socket, 500)
      ensure
        release
        linger_close(socket)
      end

      def reply(socket, status, body = '', **) = Http.write(socket, status, body, deadline_s: @write_deadline_s, **)

      # Unread request bytes would make the close a reset that discards the response; drain them, briefly.
      def linger_close(socket)
        socket.close_write
        deadline = Http.monotonic + LINGER_S
        drained = 0
        while drained < LINGER_BYTES && (left = deadline - Http.monotonic).positive? && socket.wait_readable(left)
          chunk = socket.read_nonblock(65_536, exception: false)
          break if chunk.nil?

          drained += chunk.bytesize unless chunk == :wait_readable
        end
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def respond(socket, request, early)
        return reply(socket, 421) unless allowed_host?(request.header('host'))
        return static(socket, request) unless request.path.start_with?('/v1/')
        return reply(socket, 401, '', headers: API_HEADERS) unless authorized?(request.header('authorization'))

        body = lambda do |max|
          Http.read_body(socket, request, early, max_bytes: max, deadline: Http.monotonic + @body_deadline_s)
        end
        status, payload, type = Api.new(@hub, trace: @trace).call(request, body, LIMITS)
        reply(socket, status, payload, type:, headers: API_HEADERS)
      end

      def static(socket, request)
        name = STATIC[request.path]
        return reply(socket, 404) unless name && request.method == 'GET'

        reply(socket, 200, @assets.fetch(request.path),
              type: TYPES.fetch(File.extname(name)), headers: { 'Content-Security-Policy' => CSP })
      end

      def authorized?(header)
        given = header.to_s.delete_prefix('Bearer ')
        return false if given.empty? || given == header.to_s

        OpenSSL.fixed_length_secure_compare(Digest::SHA256.digest(given), @token_digest)
      end

      def allowed_host?(value)
        host = value.to_s.downcase
        local = ["127.0.0.1:#{@port}", "localhost:#{@port}", "[::1]:#{@port}"]
        local.include?(host) || @allow_hosts.any? { |name| [name, "#{name}:#{@port}", "#{name}:443"].include?(host) }
      end

      def reserve = @mutex.synchronize { @open < MAX_CONNECTIONS && (@open += 1) }

      def release = @mutex.synchronize { @open -= 1 }

      def refuse_busy(socket)
        reply(socket, 503, 'too many connections')
      ensure
        socket.close unless socket.closed?
      end
    end
  end
end
