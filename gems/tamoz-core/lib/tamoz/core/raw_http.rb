# frozen_string_literal: true

module Tamoz
  module Core
    # P3: the minimal raw-HTTP framing shared by the witness gateway and the
    # local model endpoint (test support) — ONE read path and ONE write path,
    # so the two servers cannot drift on request parsing or response framing.
    # Homed in tamoz-core so both consumers share it without an agent edge.
    module RawHttp
      module_function

      def read_request(client)
        client.gets
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.downcase.strip] = value.strip if value
        end
        length = headers.fetch("content-length", "0").to_i
        length.positive? ? client.read(length) : ""
      end

      def write_response(client, body, status:, reason: nil)
        reason ||= status == 200 ? "OK" : "Bad Gateway"
        client.write(
          "HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        )
      end
    end
  end
end
