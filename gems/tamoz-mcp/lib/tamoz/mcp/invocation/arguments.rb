# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      # Validates descriptor identity and arguments before any transport work.
      class Arguments
        def validate_descriptor!(descriptor)
          missing = REQUIRED_DESCRIPTOR_METHODS.reject { |method| descriptor.respond_to?(method) }
          raise ValidationError, "descriptor must respond to #{missing.join(', ')}" unless missing.empty?
          if descriptor.id.to_s.empty? || descriptor.name.to_s.empty? || descriptor.source_id.to_s.empty?
            raise ValidationError, 'descriptor id, name, and source_id must be non-empty'
          end

          descriptor
        end

        def validate_arguments!(descriptor, arguments)
          arguments = {} if arguments.nil?
          unless arguments.is_a?(Hash)
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} must be a JSON object"
          end
          assert_depth!(descriptor, arguments, 0)

          begin
            MCP::Tool::InputSchema.new(strict_schema(descriptor.input_schema || {})).validate_arguments(arguments)
          rescue MCP::Tool::InputSchema::ValidationError => e
            raise schema_validation_error(descriptor, e)
          rescue ArgumentError, JSON::NestingError
            raise malformed_arguments_error(descriptor)
          end
          arguments
        end

        def schema_validation_error(descriptor, error)
          detail = Tamoz::Error.disclosable_message(
            error.message.sub(/\AInvalid arguments:\s*/, ''),
            fallback: 'the arguments do not match the snapshotted schema'
          )
          ToolArgumentError.new("the arguments for #{descriptor.id} are invalid: #{detail}")
        end

        def malformed_arguments_error(descriptor)
          ToolArgumentError.new(
            "the arguments for #{descriptor.id} are malformed or too deeply nested"
          )
        end

        def assert_depth!(descriptor, value, depth)
          if depth > MAX_ARGUMENT_DEPTH
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} exceed the maximum nesting depth of #{MAX_ARGUMENT_DEPTH}"
          end

          case value
          when Hash
            value.each_value { |child| assert_depth!(descriptor, child, depth + 1) }
          when Array
            value.each { |child| assert_depth!(descriptor, child, depth + 1) }
          end
        end

        def strict_schema(schema)
          deep_strictify(schema.is_a?(Hash) ? schema : {})
        end

        def deep_strictify(node)
          case node
          when Hash
            stricted = {}
            node.each { |key, value| stricted[key] = deep_strictify(value) }
            stricted['additionalProperties'] = false if strictable_object?(node)
            stricted
          when Array
            node.map { |value| deep_strictify(value) }
          else
            node
          end
        end

        def strictable_object?(node)
          return false unless node.is_a?(Hash) && node.key?('properties')
          return false if node.key?('additionalProperties') || node.key?('patternProperties')
          return false if node.key?('$ref') || node.key?('$dynamicRef')

          true
        end
      end
      private_constant :Arguments
    end
  end
end
