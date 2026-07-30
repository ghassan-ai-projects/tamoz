# frozen_string_literal: true

module Tamoz
  module Evals
    class Artifact
      attr_reader :attributes, :path, :digest

      def initialize(attributes:, path:, digest:)
        @attributes = deep_freeze(attributes)
        @path = File.expand_path(path).freeze
        @digest = digest.freeze
        freeze
      end

      def [](key)
        attributes.fetch(key.to_s)
      end

      def to_h
        attributes
      end

      private

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
        when Array
          value.each { |entry| deep_freeze(entry) }
        end
        value.freeze
      end
    end
  end
end
