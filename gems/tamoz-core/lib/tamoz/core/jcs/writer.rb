# frozen_string_literal: true

module Tamoz
  module Core
    module JCS
      # Writes a Ruby value as RFC 8785 canonical JSON bytes.
      module Writer
        STRING_ESCAPES = {
          0x22 => '\\"', 0x5C => '\\\\', 0x08 => '\\b', 0x09 => '\\t', 0x0A => '\\n', 0x0C => '\\f', 0x0D => '\\r'
        }.freeze

        module_function

        def emit(value, out)
          case value
          when Hash then emit_object(value, out)
          when Array then emit_array(value, out)
          when String, Symbol then emit_string(value.to_s, out)
          when Integer then out << NumberFormat.integer_to_s(value)
          when Float then out << NumberFormat.float_to_s(value)
          else out << literal_for(value)
          end
          out
        end

        def literal_for(value)
          case value
          when true then 'true'
          when false then 'false'
          when nil then 'null'
          else raise Error, "unsupported canonical value: #{value.class}"
          end
        end

        def emit_object(value, out)
          out << '{'
          sorted_pairs(value).each_with_index do |(key, entry), index|
            out << ',' if index.positive?
            emit_string(key, out)
            out << ':'
            emit(entry, out)
          end
          out << '}'
        end

        def sorted_pairs(value)
          seen = {}
          pairs = value.map do |key, entry|
            key = String(key)
            raise Error, "duplicate canonical key after stringification: #{key}" if seen[key]

            seen[key] = true
            [key, entry]
          end
          pairs.sort_by { |(key, _)| key.encode('UTF-16BE').b }
        end

        def emit_array(value, out)
          out << '['
          value.each_with_index do |entry, index|
            out << ',' if index.positive?
            emit(entry, out)
          end
          out << ']'
        end

        def emit_string(value, out)
          out << '"'
          value.each_codepoint { |code| out << escape_codepoint(code) }
          out << '"'
        rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          raise Error, 'string is not valid UTF-8'
        end

        def escape_codepoint(code)
          STRING_ESCAPES.fetch(code) do
            raise Error, 'unpaired surrogate in string' if code.between?(0xD800, 0xDFFF)

            code < 0x20 ? format('\\u%04x', code) : code.chr(Encoding::UTF_8)
          end
        end
      end
    end
  end
end
