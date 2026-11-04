# frozen_string_literal: true

module Tamoz
  module Talk
    module Http
      # Parses a request head into a Request, refusing anything malformed.
      module Head
        module_function

        def parse(head)
          line, fields = split_head(head)
          verb, target = request_line(line)
          path, query = target.split('?', 2)
          Request.new(verb:, path:, query: URI.decode_www_form(query.to_s).to_h, headers: headers(fields))
        rescue ArgumentError
          raise Refused, 400
        end

        def split_head(head)
          raise Refused, 400 if head.include?("\n") && head.gsub("\r\n", '').include?("\n")

          line, *fields = head.split("\r\n")
          raise Refused, 400 if line.nil? || line.bytesize > MAX_REQUEST_LINE
          raise Refused, 431 if fields.length > MAX_HEADERS

          [line, fields]
        end

        def request_line(line)
          parts = line.split(/ /, -1)
          raise Refused, 400 unless parts.length == 3

          method, target, version = parts
          raise Refused, 400 unless method.match?(/\A[A-Z]{3,7}\z/) && version == 'HTTP/1.1' && target.start_with?('/')

          [method, target]
        end

        def headers(fields)
          fields.each_with_object({}) do |field, out|
            name, value = header_pair(field)
            key = name.downcase
            reject_header!(key, value, out)
            out[key] = value.strip
          end
        end

        def header_pair(field)
          raise Refused, 400 if field.start_with?(' ', "\t")

          name, value = field.split(':', 2)
          raise Refused, 400 unless value && name.match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/)

          [name, value]
        end

        def reject_header!(key, value, seen)
          raise Refused, 400 if key == 'transfer-encoding' || (SINGLE.include?(key) && seen.key?(key))
          raise Refused, 400 if key == 'content-length' && !value.strip.match?(/\A\d{1,10}\z/)
        end
      end
    end
  end
end
