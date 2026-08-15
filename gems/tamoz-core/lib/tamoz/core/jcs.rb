# frozen_string_literal: true

require "digest"

module Tamoz
  module Core
    # RFC 8785 (JSON Canonicalization Scheme) plus the domain-separated digest
    # rule from CONTRACTS.md §2-3. Number serialization follows ECMAScript
    # Number::toString (the reference semantics the shared vectors were
    # generated with); keys sort by UTF-16 code unit; strings use the JCS
    # minimal escape table; producers reject NaN, ±Infinity, -0, duplicate
    # keys, unpaired surrogates, and integers that do not round-trip through
    # an IEEE-754 double.
    #
    # canonicalize(value) accepts a Ruby value. canonicalize_json(raw)
    # strict-parses raw JSON first (duplicate keys and unpaired surrogates are
    # refused at parse time). Both produce identical bytes for the same
    # document, so a received canonical JSON document verifies against a value
    # computed in code.
    module JCS
      Error = Class.new(Tamoz::Error)

      # CONTRACTS.md §3.2 — the shared domain table. Tamoz-internal seals that
      # never cross the product boundary use "tamoz/<type>/v<major>\n" domains.
      SHARED_DOMAINS = {
        snapshot: "situation-runtime/snapshot/v1\n",
        spec: "situation-runtime/spec/v1\n",
        decision: "situation-runtime/decision/v1\n",
        intent: "situation-runtime/intent/v1\n",
        command: "situation-runtime/command/v1\n",
        event: "situation-runtime/event/v1\n",
        diagnosis_catalog: "situation-runtime/diagnosis-catalog/v1\n",
        intent_catalog: "situation-runtime/intent-catalog/v1\n",
        test: "situation-runtime/test/v1\n"
      }.freeze

      MAX_SAFE_INTEGER = 9_007_199_254_740_991 # 2**53 - 1

      module_function

      def canonicalize(value)
        emit(value, +"")
      end

      def canonicalize_json(raw)
        parse(raw).then { |value| emit(value, +"") }
      end

      # Strict-parse raw JSON and return the VALUE (no canonicalization).
      # Used by verifiers that need both the parsed document and its digest.
      def parse(raw)
        unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise Error, "document is not valid UTF-8"
        end

        scanner = Scanner.new(raw)
        value = scanner.parse_value
        scanner.eof!
        value
      end

      # "sha256:" + hex(SHA256(domain_bytes || jcs_bytes)). domain is either a
      # SHARED_DOMAINS key or a raw domain string that must end in "\n".
      def digest(domain, value)
        domain = SHARED_DOMAINS.fetch(domain) if domain.is_a?(Symbol)
        unless domain.is_a?(String) && domain.end_with?("\n")
          raise ArgumentError, "JCS digest domain must end with a newline"
        end

        "sha256:" + Digest::SHA256.hexdigest(domain + canonicalize(value))
      end

      def normalize_digest(expected)
        return expected unless expected.is_a?(String)
        return "sha256:#{expected.unpack1("H*")}" if expected.bytesize == 32

        expected
      end

      def digest_bytes(expected)
        normalized = normalize_digest(expected)
        return normalized unless normalized.is_a?(String) &&
                                 normalized.match?(/\Asha256:[0-9a-f]{64}\z/)

        [normalized.delete_prefix("sha256:")].pack("H*")
      end

      # Constant-time comparison; verification is recomputation, never a
      # locally-preferred value on mismatch.
      def verify(domain, value, expected)
        expected = normalize_digest(expected)
        return false unless expected.is_a?(String) && expected.start_with?("sha256:")

        actual = digest(domain, value)
        return false unless actual.bytesize == expected.bytesize

        diff = 0
        actual.each_byte.zip(expected.each_byte) { |a, b| diff |= a ^ b }
        diff.zero?
      end

      def emit(value, out)
        case value
        when Hash
          pairs = []
          seen = {}
          value.each do |key, entry|
            key = String(key)
            raise Error, "duplicate canonical key after stringification: #{key}" if seen[key]

            seen[key] = true
            pairs << [key, entry]
          end
          pairs.sort_by! { |(key, _)| key.encode("UTF-16BE").b }
          out << "{"
          pairs.each_with_index do |(key, entry), index|
            out << "," if index.positive?
            emit_string(key, out)
            out << ":"
            emit(entry, out)
          end
          out << "}"
        when Array
          out << "["
          value.each_with_index do |entry, index|
            out << "," if index.positive?
            emit(entry, out)
          end
          out << "]"
        when String
          emit_string(value, out)
        when Symbol
          emit_string(value.to_s, out)
        when Integer
          out << integer_to_s(value)
        when Float
          out << float_to_s(value)
        when TrueClass then out << "true"
        when FalseClass then out << "false"
        when NilClass then out << "null"
        else
          raise Error, "unsupported canonical value: #{value.class}"
        end
        out
      end

      def emit_string(value, out)
        out << '"'
        begin
          value.each_codepoint do |code|
            case code
            when 0x22 then out << '\\"'
            when 0x5C then out << "\\\\"
            when 0x08 then out << "\\b"
            when 0x09 then out << "\\t"
            when 0x0A then out << "\\n"
            when 0x0C then out << "\\f"
            when 0x0D then out << "\\r"
            else
              if code < 0x20
                out << format("\\u%04x", code)
              elsif code.between?(0xD800, 0xDFFF)
                raise Error, "unpaired surrogate in string"
              else
                out << code.chr(Encoding::UTF_8)
              end
            end
          end
        rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          raise Error, "string is not valid UTF-8"
        end
        out << '"'
      end

      def integer_to_s(value)
        unless value.abs <= MAX_SAFE_INTEGER || value == value.to_f
          raise Error, "integer #{value} is not exactly representable as a double"
        end

        # Integers beyond MAX_SAFE_INTEGER that survive a double round-trip
        # must serialize with ES shortest-round-trip semantics, not their exact
        # decimal (Go agrees with ES: 2**60 -> "1152921504606847000").
        return float_to_s(value.to_f) if value.abs > MAX_SAFE_INTEGER

        value.to_s
      end

      def float_to_s(value)
        raise Error, "NaN is not representable" if value.nan?
        raise Error, "infinite is not representable" if value.infinite?
        raise Error, "negative zero is not representable" if value.zero? && (1.0 / value).negative?

        digits, n = shortest_digits(value)
        body = format_number(digits, n)
        value.negative? ? "-#{body}" : body
      end

      # Ruby's Float#to_s is shortest-round-trip but keeps shapes ES would
      # drop ("5.0e-324" -> digits "5", "1.0" -> digits "1"). Extract the
      # shortest digits (trailing zeros removed only when they still
      # round-trip), then re-emit under the ES exponent-threshold rules.
      def shortest_digits(value)
        return ["0", 1] if value.zero?

        body = value.to_s
        body = body[1..] if body.start_with?("-")
        mantissa, exponent = body.split(/[eE]/, 2)
        exponent = (exponent || 0).to_i
        integer_part, fraction = mantissa.split(".", 2)
        fraction ||= ""
        digits = integer_part + fraction
        stripped = digits.sub(/\A0+/, "")
        stripped_zeros = digits.length - stripped.length
        digits = stripped.empty? ? "0" : stripped
        n = integer_part.length + exponent - stripped_zeros

        while digits.length > 1 && digits.end_with?("0")
          trimmed = digits[0...-1]
          break unless round_trips?(trimmed, n, value)

          digits = trimmed
        end
        [digits, n]
      end

      def round_trips?(digits, n, value)
        k = digits.length
        candidate =
          if k <= n
            digits + ("0" * (n - k))
          elsif n.positive?
            digits[0...n] + "." + digits[n..]
          else
            "0." + ("0" * -n) + digits
          end
        candidate.to_f == value.abs
      end

      def format_number(digits, n)
        k = digits.length
        if k <= n && n <= 21
          digits + ("0" * (n - k))
        elsif n.positive? && n <= 21
          digits[0...n] + "." + digits[n..]
        elsif n > -6 && n <= 0
          "0." + ("0" * -n) + digits
        else
          exponent = n - 1
          digits[0] + (k > 1 ? "." + digits[1..] : "") +
            "e" + (exponent.negative? ? "-" : "+") + exponent.abs.to_s
        end
      end

      # Strict JSON scanner. Refuses duplicate keys, unpaired surrogates,
      # leading zeros, non-finite numbers, negative zero, and integers that do
      # not round-trip through a double. Handles exact integers beyond
      # MAX_SAFE_INTEGER when the double representation is exact (1e20), per
      # the shared vectors.
      class Scanner
        MAX_NESTING = 512

        def initialize(raw)
          @raw = raw
          @pos = 0
          @depth = 0
        end

        def parse_value
          skip_ws
          if @depth >= MAX_NESTING
            raise Error, "maximum nesting depth exceeded"
          end

          @depth += 1
          begin
            case peek
            when "{" then parse_object
            when "[" then parse_array
            when '"' then parse_string
            when "t" then parse_literal("true", true)
            when "f" then parse_literal("false", false)
            when "n" then parse_literal("null", nil)
            when "-", "0".."9" then parse_number
            else
              raise Error, "unexpected token at #{@pos}"
            end
          ensure
            @depth -= 1
          end
        end

        def eof!
          skip_ws
          raise Error, "trailing data at #{@pos}" unless @pos == @raw.length
        end

        private

        def parse_object
          @pos += 1
          skip_ws
          object = {}
          return object if consume("}")

          loop do
            skip_ws
            raise Error, "expected string key at #{@pos}" unless peek == '"'

            key = parse_string
            skip_ws
            raise Error, "expected ':' at #{@pos}" unless consume(":")

            value = parse_value
            raise Error, "duplicate key #{key}" if object.key?(key)

            object[key] = value
            skip_ws
            if consume(",")
              next
            elsif consume("}")
              return object
            else
              raise Error, "expected ',' or '}' at #{@pos}"
            end
          end
        end

        def parse_array
          @pos += 1
          skip_ws
          array = []
          return array if consume("]")

          loop do
            array << parse_value
            skip_ws
            if consume(",")
              next
            elsif consume("]")
              return array
            else
              raise Error, "expected ',' or ']' at #{@pos}"
            end
          end
        end

        def parse_string
          @pos += 1
          out = +""
          loop do
            raise Error, "unterminated string" if @pos >= @raw.length

            char = @raw[@pos]
            if char == '"'
              @pos += 1
              return out
            elsif char == "\\"
              @pos += 1
              out << parse_escape
            else
              if char.ord < 0x20
                raise Error, "unescaped control character in string at #{@pos}"
              end

              out << char
              @pos += 1
            end
          end
        end

        def parse_escape
          raise Error, "unterminated escape" if @pos >= @raw.length

          char = @raw[@pos]
          @pos += 1
          case char
          when '"' then '"'
          when "\\" then "\\"
          when "/" then "/"
          when "b" then "\b"
          when "f" then "\f"
          when "n" then "\n"
          when "r" then "\r"
          when "t" then "\t"
          when "u" then parse_unicode_escape
          else
            raise Error, "invalid escape \\#{char}"
          end
        end

        def parse_unicode_escape
          code = hex4
          if code.between?(0xD800, 0xDBFF)
            unless @raw[@pos] == "\\" && @raw[@pos + 1] == "u"
              raise Error, "lone high surrogate"
            end

            @pos += 2
            low = hex4
            unless low.between?(0xDC00, 0xDFFF)
              raise Error, "unpaired high surrogate"
            end

            (0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8)
          elsif code.between?(0xDC00, 0xDFFF)
            raise Error, "lone low surrogate"
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
          consume("-")
          raise Error, "bad number at #{@pos}" unless digit?(peek)

          if consume("0")
            raise Error, "leading zero at #{@pos}" if digit?(peek)
          else
            @pos += 1 while digit?(peek)
          end

          if peek == "."
            @pos += 1
            raise Error, "missing fraction at #{@pos}" unless digit?(peek)

            @pos += 1 while digit?(peek)
          end

          if peek == "e" || peek == "E"
            @pos += 1
            @pos += 1 if peek == "+" || peek == "-"
            raise Error, "missing exponent at #{@pos}" unless digit?(peek)

            @pos += 1 while digit?(peek)
          end

          text = @raw[start...@pos]
          number_from(text)
        end

        def number_from(text)
          mantissa = text.delete_prefix("-").split(/[eE]/, 2).first
          raise Error, "negative zero is not representable" if mantissa.to_f.zero? && text.start_with?("-")

          if text.match?(/[.eE]/)
            value = Float(text)
            raise Error, "non-finite number #{text}" unless value.finite?

            value
          else
            value = text.to_i
            unless value.abs <= JCS::MAX_SAFE_INTEGER || value == value.to_f
              raise Error, "integer #{text} is not exactly representable as a double"
            end

            value
          end
        end

        def parse_literal(literal, result)
          unless @raw[@pos, literal.length] == literal
            raise Error, "invalid literal at #{@pos}"
          end

          @pos += literal.length
          result
        end

        def consume(char)
          return false unless @raw[@pos] == char

          @pos += 1
          true
        end

        def peek
          @raw[@pos]
        end

        def digit?(char)
          char && char >= "0" && char <= "9"
        end

        def skip_ws
          char = @raw[@pos]
          while char == " " || char == "\t" || char == "\n" || char == "\r"
            @pos += 1
            char = @raw[@pos]
          end
        end
      end
    end
  end
end
