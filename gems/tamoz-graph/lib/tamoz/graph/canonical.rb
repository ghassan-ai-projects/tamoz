# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Graph
    module Canonical
      DIGEST_VERSION = 1

      module_function

      def json(value)
        JSON.generate(sort(value))
      end

      def digest(value, domain:)
        body = "#{domain}\0v#{DIGEST_VERSION}\0#{json(value)}"
        "sha256:#{Digest::SHA256.hexdigest(body)}"
      end

      def sort(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            source_key = value.key?(key) ? key : key.to_sym
            [key, sort(value.fetch(source_key))]
          end
        when Array
          value.map { |entry| sort(entry) }
        when Symbol
          value.to_s
        when NilClass, TrueClass, FalseClass, Integer, Float, String
          value
        else
          raise GraphDefinitionError, "non-canonical definition value #{value.class}"
        end
      end
      private_class_method :sort
    end

    private_constant :Canonical
  end
end
