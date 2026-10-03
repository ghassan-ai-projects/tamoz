# frozen_string_literal: true

module Tamoz
  module Mcp
    module Elicitation
      # Validates operator answers against the requested schemas.
      class Answers
        def input_response(field, answers, single_field:)
          id = field.fetch('id')
          content = single_field ? answers : answer_for_field(answers, id)
          validate_answer_content!(field, content)
          { 'action' => 'accept', 'content' => content }
        end

        def answer_for_field(answers, id)
          answers[id] || raise(
            ToolArgumentError,
            "the answer to an MCP elicitation is missing the fields for request #{id}"
          )
        end

        def validate_answer_content!(field, content)
          unless content.is_a?(Hash)
            raise ToolArgumentError,
                  'the answer to an MCP elicitation must be a JSON object of field values'
          end

          schema = field.fetch('schema')
          begin
            MCP::Tool::InputSchema.new(strict_schema(schema)).validate_arguments(content)
          rescue MCP::Tool::InputSchema::ValidationError => e
            detail = Tamoz::Error.disclosable_message(
              e.message.sub(/\AInvalid arguments:\s*/, ''),
              fallback: 'the answer does not match the requested schema'
            )
            raise ToolArgumentError,
                  "the answer to an MCP elicitation is invalid: #{detail}"
          rescue ArgumentError, JSON::NestingError
            raise ToolArgumentError,
                  'the answer to an MCP elicitation is malformed or too deeply nested'
          end
          content
        end

        def strict_schema(schema)
          candidate = schema.is_a?(Hash) ? schema : {}
          root = deep_strictify(candidate)
          root = root.merge('additionalProperties' => false) if strictable_object?(candidate)
          root
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
      private_constant :Answers
    end
  end
end
