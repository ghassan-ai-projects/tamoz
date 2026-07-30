# frozen_string_literal: true

module Tamoz
  module Evals
    class Artifact
      attr_reader :attributes, :path, :digest

      def initialize(attributes:, path:, digest:)
        @attributes = DeepFreeze.call(attributes)
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
    end
  end
end
