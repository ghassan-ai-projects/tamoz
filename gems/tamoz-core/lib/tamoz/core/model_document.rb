# frozen_string_literal: true

module Tamoz
  module Core
    # Typed reading of the JSON documents a model returns.
    module ModelDocument
      module_function

      # Strict JSON-object parse for untrusted model documents: accepts an already
      # parsed Hash (symbol keys normalized to strings), strips a markdown fence,
      # and refuses non-object documents. Homed here so durable-memory
      # consolidation and the deliberation loop share one implementation.
      def parse_object(value)
        return value.transform_keys(&:to_s) if value.is_a?(Hash)

        text = String(value).strip
        text = text.delete_prefix('```json').delete_prefix('```').delete_suffix('```').strip
        document = JSON.parse(text)
        raise ProtocolError, 'model response must be a JSON object' unless document.is_a?(Hash)

        document
      rescue JSON::ParserError => e
        raise ProtocolError, "model returned invalid JSON: #{e.message}"
      end

      # Typed string coercion for document fields: refuses non-strings under the
      # field's name and returns a frozen copy.
      def string(value, name:)
        raise ProtocolError, "#{name} must be a string" unless value.is_a?(String)

        value.dup.freeze
      end

      # Typed string-array coercion; every entry is validated through #string.
      def strings(value, name:)
        raise ProtocolError, "#{name} must be an array" unless value.is_a?(Array)

        value.map { |entry| string(entry, name: "#{name} entry") }.freeze
      end
    end
    private_constant :ModelDocument
  end
end
