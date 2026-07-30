# frozen_string_literal: true

require "json"
require "set"

module Tamoz
  module Evals
    class DuplicateKeyDetector
      WHITESPACE = [" ", "\t", "\r", "\n"].freeze

      def self.validate!(text)
        new(text).validate!
      end

      def initialize(text)
        @text = text
        @index = 0
      end

      def validate!
        skip_whitespace
        parse_value
        skip_whitespace
        raise InvalidArtifactError, "unexpected trailing JSON content" unless eof?

        true
      rescue JSON::ParserError => error
        raise InvalidArtifactError, "invalid JSON: #{error.message}"
      end

      private

      def parse_value
        case current
        when "{" then parse_object
        when "[" then parse_array
        when '"' then parse_string
        when nil then raise InvalidArtifactError, "unexpected end of JSON"
        else parse_scalar
        end
      end

      def parse_object
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
          parse_value
          skip_whitespace

          return advance("}") if current == "}"

          advance(",")
          skip_whitespace
        end
      end

      def parse_array
        advance("[")
        skip_whitespace
        return advance("]") if current == "]"

        loop do
          parse_value
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
          character = current
          @index += 1

          if escaped
            escaped = false
          elsif character == "\\"
            escaped = true
          elsif character == '"'
            literal = @text.byteslice(start...@index)
            return JSON.parse(literal)
          elsif character.ord < 0x20
            raise InvalidArtifactError, "unescaped control character in JSON string"
          end
        end

        raise InvalidArtifactError, "unterminated JSON string"
      end

      def parse_scalar
        start = @index
        @index += 1 until eof? || WHITESPACE.include?(current) || [",", "]", "}"].include?(current)
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
