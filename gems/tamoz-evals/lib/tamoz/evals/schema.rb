# frozen_string_literal: true

require "json"

module Tamoz
  module Evals
    class Schema
      SCHEMA_ROOT = File.expand_path("../../../schemas", __dir__).freeze
      TYPES = {
        "array" => Array,
        "boolean" => [TrueClass, FalseClass],
        "integer" => Integer,
        "null" => NilClass,
        "number" => Numeric,
        "object" => Hash,
        "string" => String
      }.freeze

      def self.load(artifact_type)
        path = File.join(SCHEMA_ROOT, "#{artifact_type}.schema.json")
        raise UnsupportedFormatError, "unsupported artifact type: #{artifact_type.inspect}" unless File.file?(path)

        new(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
      end

      def initialize(document)
        @document = document
      end

      def validate!(value)
        validate_node!(@document, value, "$")
        true
      end

      private

      def validate_node!(schema, value, path)
        schema = resolve_reference(schema.fetch("$ref")) if schema.key?("$ref")

        if schema.key?("allOf")
          schema.fetch("allOf").each { |branch| validate_node!(branch, value, path) }
        end

        validate_any_of!(schema.fetch("anyOf"), value, path) if schema.key?("anyOf")
        validate_type!(schema.fetch("type"), value, path) if schema.key?("type")
        validate_const_and_enum!(schema, value, path)

        case value
        when Hash then validate_object!(schema, value, path)
        when Array then validate_array!(schema, value, path)
        when String then validate_string!(schema, value, path)
        when Integer then validate_integer!(schema, value, path)
        end
      end

      def resolve_reference(reference)
        unless reference.start_with?("#/")
          raise SchemaError, "external schema reference is forbidden: #{reference}"
        end

        reference.delete_prefix("#/").split("/").reduce(@document) do |node, token|
          node.fetch(token.gsub("~1", "/").gsub("~0", "~"))
        end
      rescue KeyError
        raise SchemaError, "schema reference does not exist: #{reference}"
      end

      def validate_any_of!(branches, value, path)
        matches = branches.count do |branch|
          validate_node!(branch, value, path)
          true
        rescue SchemaError
          false
        end
        raise SchemaError, "#{path}: expected exactly one anyOf branch, matched #{matches}" unless matches == 1
      end

      def validate_type!(expected, value, path)
        types = Array(expected)
        matches = types.any? do |name|
          ruby_types = TYPES.fetch(name) { raise SchemaError, "schema has unsupported type #{name.inspect}" }
          Array(ruby_types).any? { |ruby_type| value.is_a?(ruby_type) } &&
            !(name == "integer" && [TrueClass, FalseClass].any? { |type| value.is_a?(type) })
        end
        raise SchemaError, "#{path}: expected #{types.join(" or ")}, got #{value.class}" unless matches
      end

      def validate_const_and_enum!(schema, value, path)
        if schema.key?("const") && value != schema.fetch("const")
          raise SchemaError, "#{path}: expected #{schema.fetch("const").inspect}"
        end
        if schema.key?("enum") && !schema.fetch("enum").include?(value)
          raise SchemaError, "#{path}: value is not in the allowed set"
        end
      end

      def validate_object!(schema, value, path)
        Array(schema["required"]).each do |key|
          raise SchemaError, "#{path}: missing required property #{key.inspect}" unless value.key?(key)
        end

        properties = schema.fetch("properties", {})
        if schema["additionalProperties"] == false
          unknown = value.keys - properties.keys
          raise SchemaError, "#{path}: unknown properties #{unknown.sort.inspect}" unless unknown.empty?
        end

        properties.each do |key, child_schema|
          validate_node!(child_schema, value.fetch(key), "#{path}.#{key}") if value.key?(key)
        end
      end

      def validate_array!(schema, value, path)
        minimum = schema["minItems"]
        maximum = schema["maxItems"]
        raise SchemaError, "#{path}: has fewer than #{minimum} items" if minimum && value.length < minimum
        raise SchemaError, "#{path}: has more than #{maximum} items" if maximum && value.length > maximum
        if schema["uniqueItems"] && value.uniq.length != value.length
          raise SchemaError, "#{path}: items must be unique"
        end

        return unless schema.key?("items")

        value.each_with_index do |entry, index|
          validate_node!(schema.fetch("items"), entry, "#{path}[#{index}]")
        end
      end

      def validate_string!(schema, value, path)
        minimum = schema["minLength"]
        maximum = schema["maxLength"]
        raise SchemaError, "#{path}: string is shorter than #{minimum}" if minimum && value.length < minimum
        raise SchemaError, "#{path}: string is longer than #{maximum}" if maximum && value.length > maximum
        if schema.key?("pattern") && !Regexp.new(schema.fetch("pattern")).match?(value)
          raise SchemaError, "#{path}: string does not match required pattern"
        end
      end

      def validate_integer!(schema, value, path)
        minimum = schema["minimum"]
        maximum = schema["maximum"]
        raise SchemaError, "#{path}: value is below #{minimum}" if minimum && value < minimum
        raise SchemaError, "#{path}: value is above #{maximum}" if maximum && value > maximum
      end
    end
  end
end
