# frozen_string_literal: true

module Tamoz
  module Core
    module JCS
      # Strict JSON scanner. Refuses duplicate keys, unpaired surrogates,
      # leading zeros, non-finite numbers, negative zero, and integers that do
      # not round-trip through a double. Handles exact integers beyond
      # MAX_SAFE_INTEGER when the double representation is exact (1e20), per
      # the shared vectors.
      class Scanner
        MAX_NESTING = 512
        WHITESPACE = [' ', "\t", "\n", "\r"].freeze
        SIMPLE_ESCAPES = {
          '"' => '"', '\\' => '\\', '/' => '/', 'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t"
        }.freeze
        private_constant :SIMPLE_ESCAPES, :WHITESPACE

        def initialize(raw)
          @raw = raw
          @pos = 0
          @depth = 0
        end

        def parse_value
          skip_ws
          raise Error, 'maximum nesting depth exceeded' if @depth >= MAX_NESTING

          @depth += 1
          begin
            parse_token
          ensure
            @depth -= 1
          end
        end

        def eof!
          skip_ws
          raise Error, "trailing data at #{@pos}" unless @pos == @raw.length
        end

        private

        def parse_token
          case peek
          when '{' then parse_object
          when '[' then parse_array
          when '"' then parse_string
          when 't' then parse_literal('true', true)
          when 'f' then parse_literal('false', false)
          when 'n' then parse_literal('null', nil)
          when '-', '0'..'9' then parse_number
          else raise Error, "unexpected token at #{@pos}"
          end
        end

        def parse_object
          @pos += 1
          skip_ws
          object = {}
          return object if consume('}')

          loop do
            key, value = parse_member
            raise Error, "duplicate key #{key}" if object.key?(key)

            object[key] = value
            return object if container_closed?('}')
          end
        end

        def parse_member
          skip_ws
          raise Error, "expected string key at #{@pos}" unless peek == '"'

          key = parse_string
          skip_ws
          raise Error, "expected ':' at #{@pos}" unless consume(':')

          [key, parse_value]
        end

        def parse_array
          @pos += 1
          skip_ws
          array = []
          return array if consume(']')

          loop do
            array << parse_value
            return array if container_closed?(']')
          end
        end

        def container_closed?(closer)
          skip_ws
          return false if consume(',')
          return true if consume(closer)

          raise Error, "expected ',' or '#{closer}' at #{@pos}"
        end

        def parse_string
          @pos += 1
          out = String.new(encoding: Encoding::BINARY)
          loop do
            raise Error, 'unterminated string' if @pos >= @raw.length

            char = @raw[@pos]
            if char == '"'
              @pos += 1
              return out.force_encoding(Encoding::UTF_8)
            elsif char == '\\'
              @pos += 1
              out << parse_escape.b
            else
              raise Error, "unescaped control character in string at #{@pos}" if char.ord < 0x20

              out << char
              @pos += 1
            end
          end
        end

        def parse_escape
          raise Error, 'unterminated escape' if @pos >= @raw.length

          char = @raw[@pos]
          @pos += 1
          return parse_unicode_escape if char == 'u'

          SIMPLE_ESCAPES.fetch(char) { raise Error, "invalid escape \\#{char}" }
        end

        def parse_unicode_escape
          code = hex4
          if code.between?(0xD800, 0xDBFF)
            raise Error, 'lone high surrogate' unless @raw[@pos] == '\\' && @raw[@pos + 1] == 'u'

            @pos += 2
            low = hex4
            raise Error, 'unpaired high surrogate' unless low.between?(0xDC00, 0xDFFF)

            (0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8)
          elsif code.between?(0xDC00, 0xDFFF)
            raise Error, 'lone low surrogate'
          else
            code.chr(Encoding::UTF_8)
          end
        end

        def hex4
          digits = @raw[@pos, 4]
          unless digits && digits.length == 4 && digits.match?(/\A[0-9a-fA-F]{4}\z/)
            raise Error, "short or invalid \\u escape at #{@pos}"
          end

          @pos += 4
          digits.to_i(16)
        end

        def parse_number
          start = @pos
          consume('-')
          scan_integer_part
          scan_fraction
          scan_exponent
          number_from(@raw[start...@pos])
        end

        def scan_integer_part
          raise Error, "bad number at #{@pos}" unless digit?(peek)

          if consume('0')
            raise Error, "leading zero at #{@pos}" if digit?(peek)
          else
            skip_digits
          end
        end

        def scan_fraction
          return unless consume('.')
          raise Error, "missing fraction at #{@pos}" unless digit?(peek)

          skip_digits
        end

        def scan_exponent
          return unless consume('e') || consume('E')

          consume('+') || consume('-')
          raise Error, "missing exponent at #{@pos}" unless digit?(peek)

          skip_digits
        end

        def skip_digits
          @pos += 1 while digit?(peek)
        end

        def number_from(text)
          mantissa = text.delete_prefix('-').split(/[eE]/, 2).first
          raise Error, 'negative zero is not representable' if mantissa.to_f.zero? && text.start_with?('-')

          text.match?(/[.eE]/) ? float_from(text) : integer_from(text)
        end

        def float_from(text)
          value = Float(text)
          return value if value.finite?

          raise Error, "non-finite number #{text}"
        end

        def integer_from(text)
          value = text.to_i
          return value if NumberFormat.exact_double?(value)

          raise Error, "integer #{text} is not exactly representable as a double"
        end

        def parse_literal(literal, result)
          raise Error, "invalid literal at #{@pos}" unless @raw[@pos, literal.length] == literal

          @pos += literal.length
          result
        end

        def consume(char)
          return unless @raw[@pos] == char

          @pos += 1
        end

        def peek
          @raw[@pos]
        end

        def digit?(char)
          char && char >= '0' && char <= '9'
        end

        def skip_ws
          char = @raw[@pos]
          while WHITESPACE.include?(char)
            @pos += 1
            char = @raw[@pos]
          end
        end
      end
    end
  end
end
