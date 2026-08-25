# frozen_string_literal: true

require "json"
require "time"
require "tamoz/core"
require "tamoz/stream/errors"

module Tamoz
  module Stream
    module NotificationContract
      CONTRACT_ID = "urn:situation-runtime:notification-contract:v1"
      TRACEPARENT_PATTERN = /\A(?:00|[0-9a-f]{2})-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/.freeze

      class ConformanceError < StreamError
        CATEGORY = "stream_notification_contract"
      end

      module_function

      def validate!(event)
        document = event.envelope
        raise ConformanceError, "notification envelope must be a Hash" unless document.is_a?(Hash)

        contract = load_contract
        validate_schema!(document, contract, "$")
        validate_conditional_branches!(document, contract)
        validate_relations!(document)
        event
      rescue KeyError, TypeError => error
        raise ConformanceError, "notification contract is malformed: #{error.message}"
      end

      # if/then branches: a document matching an "if" schema must also
      # satisfy that branch's "then" schema.
      def validate_conditional_branches!(document, contract)
        contract.fetch("allOf").each do |branch|
          next unless matches_schema?(document, branch.fetch("if"))

          validate_schema!(document, branch.fetch("then"), "$")
        end
      end

      def known_family?(type)
        base = String(type).sub(/\.v\d+\z/, "")
        notification_types.any? { |known| known.sub(/\.v\d+\z/, "") == base }
      end

      def supported_type?(type)
        notification_types.include?(String(type))
      end

      def load_contract
        @contract ||= Tamoz::Core.deep_freeze(
          JSON.parse(File.read(contract_path, encoding: Encoding::UTF_8))
        )
      rescue Errno::ENOENT, JSON::ParserError => error
        raise ConformanceError, "notification contract cannot be loaded: #{error.class}"
      end

      def notification_types
        load_contract.fetch("properties").fetch("type").fetch("enum")
      end

      def contract_path
        File.expand_path("../../../contracts/notification-contract-v1.json", __dir__)
      end

      def validate_relations!(document)
        data = document.fetch("data")
        unless data.fetch("source_authority") == document.fetch("source")
          raise ConformanceError, "data.source_authority must equal CloudEvent.source"
        end
        unless data.fetch("tenant_id") == document.fetch("tenantid")
          raise ConformanceError, "notification tenant does not match CloudEvent tenant"
        end
        unless document.fetch("dataschema") == CONTRACT_ID
          raise ConformanceError, "notification dataschema is not pinned to #{CONTRACT_ID}"
        end
        if document["tracestate"] && !document["traceparent"]
          raise ConformanceError, "tracestate requires traceparent"
        end
        if document["traceparent"] && !document.fetch("traceparent").match?(TRACEPARENT_PATTERN)
          raise ConformanceError, "traceparent is malformed"
        end
        if document["tracestate"] && document.fetch("tracestate").bytesize > 512
          raise ConformanceError, "tracestate exceeds 512 bytes"
        end
      end

      def validate_schema!(value, schema, path)
        validate_type!(value, schema["type"], path) if schema["type"]
        validate_scalar_constraints!(value, schema, path)
        validate_object_constraints!(value, schema, path)
        validate_children!(value, schema.fetch("properties", {}), path)
        validate_items!(value, schema, path)
      end

      def validate_scalar_constraints!(value, schema, path)
        if schema.key?("const") && value != schema.fetch("const")
          raise ConformanceError, "#{path} does not equal its contract constant"
        end
        if schema["enum"] && !schema.fetch("enum").include?(value)
          raise ConformanceError, "#{path} is outside its contract vocabulary"
        end
        if schema["minimum"] && (!numeric?(value) || value < schema.fetch("minimum"))
          raise ConformanceError, "#{path} is below its contract minimum"
        end
        if schema["minLength"] && (!value.is_a?(String) || value.length < schema.fetch("minLength"))
          raise ConformanceError, "#{path} is shorter than its contract minimum"
        end
        if schema["maxLength"] && (!value.is_a?(String) || value.length > schema.fetch("maxLength"))
          raise ConformanceError, "#{path} is longer than its contract maximum"
        end
        if schema["pattern"] && (!value.is_a?(String) || !value.match?(Regexp.new(schema.fetch("pattern"))))
          raise ConformanceError, "#{path} does not match its contract pattern"
        end
        validate_format!(value, schema.fetch("format"), path) if schema["format"]
      end

      def validate_object_constraints!(value, schema, path)
        required = Array(schema["required"])
        missing = required.reject { |key| value.is_a?(Hash) && value.key?(key) }
        raise ConformanceError, "#{path} is missing #{missing.join(", ")}" unless missing.empty?
        return unless schema["additionalProperties"] == false && value.is_a?(Hash)

        unknown = value.keys - schema.fetch("properties", {}).keys
        raise ConformanceError, "#{path} contains unsupported fields #{unknown.join(", ")}" unless unknown.empty?
      end

      def validate_children!(value, properties, path)
        properties.each do |key, child|
          next unless value.is_a?(Hash) && value.key?(key)

          validate_schema!(value.fetch(key), child, "#{path}.#{key}")
        end
      end

      def validate_items!(value, schema, path)
        return unless schema["items"] && value.is_a?(Array)

        value.each_with_index do |entry, index|
          validate_schema!(entry, schema.fetch("items"), "#{path}[#{index}]")
        end
      end

      def matches_schema?(value, schema)
        return false if schema["type"] && !type_matches?(value, schema.fetch("type"))
        return false if schema["const"] && value != schema.fetch("const")

        schema.fetch("properties", {}).all? do |key, child|
          value.is_a?(Hash) && value.key?(key) && matches_schema?(value.fetch(key), child)
        end
      end

      def validate_format!(value, format, path)
        return if format != "date-time"
        return if value.is_a?(String) && Time.iso8601(value)

        raise ConformanceError, "#{path} is not an RFC3339 date-time"
      rescue ArgumentError
        raise ConformanceError, "#{path} is not an RFC3339 date-time"
      end

      def numeric?(value)
        value.is_a?(Numeric)
      end

      def validate_type!(value, type, path)
        return if type_matches?(value, type)

        raise ConformanceError, "#{path} has the wrong JSON type"
      end

      def type_matches?(value, type)
        Array(type).any? do |entry|
          case entry
          when "object" then value.is_a?(Hash)
          when "array" then value.is_a?(Array)
          when "string" then value.is_a?(String)
          when "integer" then value.is_a?(Integer)
          when "number" then numeric?(value)
          when "boolean" then value == true || value == false
          when "null" then value.nil?
          else false
          end
        end
      end
    end
  end
end
