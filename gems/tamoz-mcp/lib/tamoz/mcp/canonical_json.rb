# frozen_string_literal: true

require 'json'

module Tamoz
  module Mcp
    # Deterministic JSON for digests: object keys sorted, strings NFC-
    # normalized UTF-8, no locale dependence. Mirrors the tamoz-evals
    # canonicalizer's rules (duplicated deliberately: tamoz-mcp may not
    # depend on tamoz-evals).
    # :reek:TooManyStatements — `normalize` is one exhaustive case over the JSON
    # type set; every arm is a distinct type and the list IS the contract.
    module CanonicalJSON
      module_function

      def dump(value)
        JSON.generate(normalize(value))
      end

      # Recursively freezes a JSON-shaped value in place (the shared freezer
      # for catalog/invocation/elicitation snapshots — all three deep-froze
      # their own byte-identical copy of this before it moved here).
      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |entry| deep_freeze(entry) }
        when Array
          value.each { |entry| deep_freeze(entry) }
        end
        value.freeze
      end

      def normalize(value, depth = 0)
        raise ValidationError, 'catalog value nesting exceeds 100' if depth > 100

        case value
        when Hash
          normalize_object(value, depth)
        when Array
          value.map { |entry| normalize(entry, depth + 1) }
        when String
          normalize_string(value)
        when Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          normalize_string(value.to_s)
        else
          raise ValidationError, "unsupported catalog value: #{value.class}"
        end
      end

      def normalize_object(value, depth)
        normalized = {}
        value.each do |key, entry|
          normalized[normalize_string(key.to_s)] = normalize(entry, depth + 1)
        end
        normalized.keys.sort.to_h { |key| [key, normalized.fetch(key)] }
      end

      def normalize_string(value)
        text = value.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub('') unless text.valid_encoding?

        text.unicode_normalize(:nfc)
      end
    end
  end
end
