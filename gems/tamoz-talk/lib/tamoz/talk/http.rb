# frozen_string_literal: true

require 'io/wait'
require 'uri'

module Tamoz
  module Talk
    # A strict HTTP/1.1 reader and writer for hostile input: every read has a deadline, every size a cap.
    module Http
      MAX_REQUEST_LINE = 2048
      MAX_HEAD_BYTES = 16_384
      MAX_HEADERS = 64
      HEAD_DEADLINE_S = 5.0
      WRITE_DEADLINE_S = 10.0
      SINGLE = %w[host authorization content-type content-length].freeze
      BODY_DEADLINE_S = 30.0
      REASONS = {
        200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized', 404 => 'Not Found', 405 => 'Method Not Allowed',
        408 => 'Request Timeout',
        413 => 'Content Too Large', 415 => 'Unsupported Media Type', 421 => 'Misdirected Request',
        429 => 'Too Many Requests', 431 => 'Request Header Fields Too Large', 500 => 'Internal Server Error',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable'
      }.freeze

      # A request the server refuses, carrying the HTTP status to answer with.
      class Refused < StandardError
        attr_reader :status

        def initialize(status, message = REASONS.fetch(status))
          @status = status
          super(message)
        end
      end

      Request = Data.define(:verb, :path, :query, :headers) do
        def header(name) = headers[name.downcase]

        def content_length = headers.fetch('content-length', '0').to_i
      end

      module_function

      def read_head(socket, deadline: monotonic + HEAD_DEADLINE_S)
        buffer = +''.b
        until (ending = buffer.index("\r\n\r\n"))
          raise Refused, 431 if buffer.bytesize > MAX_HEAD_BYTES

          buffer << read_some(socket, MAX_HEAD_BYTES + 4 - buffer.bytesize, deadline)
        end
        raise Refused, 431 if ending > MAX_HEAD_BYTES

        [Head.parse(buffer.byteslice(0, ending)), buffer.byteslice((ending + 4)..)]
      end

      def read_body(socket, request, early, max_bytes:, deadline: monotonic + BODY_DEADLINE_S)
        length = request.content_length
        raise Refused, 413 if length > max_bytes

        body = early.byteslice(0, length).b
        body << read_some(socket, length - body.bytesize, deadline) while body.bytesize < length
        body
      end

      def write(socket, status, body = '', headers: {}, deadline_s: WRITE_DEADLINE_S)
        body = body.b
        head = "HTTP/1.1 #{status} #{REASONS.fetch(status)}\r\n"
        { 'Content-Type' => 'text/plain; charset=utf-8', 'Content-Length' => body.bytesize.to_s,
          'Connection' => 'close', 'X-Content-Type-Options' => 'nosniff' }
          .merge(headers).each { |name, value| head << "#{name}: #{value}\r\n" }
        write_all(socket, head.b + "\r\n".b + body, monotonic + deadline_s)
      rescue IOError, SystemCallError
        nil
      end

      def write_all(socket, bytes, deadline)
        until bytes.empty?
          written = socket.write_nonblock(bytes, exception: false)
          if written == :wait_writable
            left = deadline - monotonic
            raise IOError, 'the client stopped reading' unless left.positive? && socket.wait_writable(left)
          else
            bytes = bytes.byteslice(written..)
          end
        end
      end

      def read_some(socket, limit, deadline)
        loop do
          chunk = socket.read_nonblock(limit, exception: false)
          raise EOFError, 'the client closed the connection' if chunk.nil?
          return chunk unless chunk == :wait_readable

          left = deadline - monotonic
          raise Refused, 408 unless left.positive? && socket.wait_readable(left)
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

require_relative 'http/head'
