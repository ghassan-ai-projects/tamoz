# frozen_string_literal: true

require "json"
require "set"

module Tamoz
  module Evals
    class DuplicateKeyDetector
      MAX_NESTING = 100
      WHITESPACE = [" ", "\t", "\r", "\n"].freeze
      SCALAR_TERMINATORS = (WHITESPACE + [",", "]", "}"]).freeze
      BACKSLASH_BYTE = 0x5c
      QUOTE_BYTE = 0x22

      def self.validate!(text)
        new(text).validate!
      end

      def initialize(text)
        @text = text
        @index = 0
      end

      def validate!
        skip_whitespace
        parse_value(0)
        skip_whitespace
        raise InvalidArtifactError, "unexpected trailing JSON content" unless eof?

        true
      rescue JSON::ParserError => error
        raise InvalidArtifactError, "invalid JSON: #{error.message}"
      end

      private

      def parse_value(depth)
        raise InvalidArtifactError, "JSON nesting exceeds #{MAX_NESTING}" if depth > MAX_NESTING

        case current
        when "{" then parse_object(depth)
        when "[" then parse_array(depth)
        when '"' then parse_string
        when nil then raise InvalidArtifactError, "unexpected end of JSON"
        else parse_scalar
        end
      end

      def parse_object(depth)
        advance("{")
        skip_whitespace
        return advance("}") if current == "}"

        keys = Set.new
        loop do
          raise InvalidArtifactError, "object key must be a JSON string" unless current == '"'

          key = parse_string
          raise InvalidArtifactError, "duplicate key #{key.inspect}" unless keys.add?(key)

          skip_whitespace
          advance(":")
          skip_whitespace
          parse_value(depth + 1)
          skip_whitespace

          return advance("}") if current == "}"

          advance(",")
          skip_whitespace
        end
      end

      def parse_array(depth)
        advance("[")
        skip_whitespace
        return advance("]") if current == "]"

        loop do
          parse_value(depth + 1)
          skip_whitespace
          return advance("]") if current == "]"

          advance(",")
          skip_whitespace
        end
      end

      def parse_string
        start = @index
        advance('"')
        escaped = false

        until eof?
          byte = @text.getbyte(@index)
          @index += 1

          if escaped
            escaped = false
          elsif byte == BACKSLASH_BYTE
            escaped = true
          elsif byte == QUOTE_BYTE
            literal = @text.byteslice(start...@index)
            return JSON.parse(literal)
          elsif byte < 0x20
            raise InvalidArtifactError, "unescaped control character in JSON string"
          end
        end

        raise InvalidArtifactError, "unterminated JSON string"
      end

      def parse_scalar
        start = @index
        @index += 1 until eof? || SCALAR_TERMINATORS.include?(current)
        token = @text.byteslice(start...@index)
        JSON.parse(token)
      end

      def skip_whitespace
        @index += 1 while WHITESPACE.include?(current)
      end

      def advance(expected)
        unless current == expected
          raise InvalidArtifactError,
                "expected #{expected.inspect} at byte #{@index}, got #{current.inspect}"
        end

        @index += 1
      end

      def current
        @text.byteslice(@index, 1)
      end

      def eof?
        @index >= @text.bytesize
      end
    end
  end
end
