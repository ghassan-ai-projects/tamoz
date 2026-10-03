# frozen_string_literal: true

module Tamoz
  module Mcp
    module Elicitation
      # Validates and bounds the fields requested by an MCP server.
      class Fields
        def field_descriptor(id, params)
          request = validate_input_request!(params)
          schema = validate_schema_present!(request['requestedSchema'])
          # Schema content is server-controlled text that rides into the durable
          # interrupt: every string in it (property names, descriptions, enum
          # values, defaults, ...) gets the same control-strip + byte-bound
          # treatment as `message`, so the interrupt can never carry raw control
          # characters or unbounded server content.
          schema = sanitize_schema(schema)
          validate_field_schema!(schema)

          {
            'id' => bounded_message(id.to_s),
            'message' => bounded_message(request['message']),
            'schema' => CanonicalJSON.deep_freeze(CanonicalJSON.normalize(schema))
          }.freeze
        end

        def validate_input_request!(params)
          unless params.is_a?(Hash) && params['method'] == ELICITATION_METHOD &&
                 params['params'].is_a?(Hash)
            raise ToolPolicyError,
                  'an MCP server returned an input request that is not a supported elicitation'
          end

          params['params']
        end

        def validate_schema_present!(schema)
          unless schema.is_a?(Hash)
            raise ToolPolicyError,
                  'an MCP server returned an elicitation request without a requested schema'
          end

          schema
        end

        def sanitize_schema(node)
          case node
          when Hash
            node.each_with_object({}) do |(key, value), out|
              out[bounded_message(key.to_s)] = sanitize_schema(value)
            end
          when Array
            node.map { |entry| sanitize_schema(entry) }
          when String
            bounded_message(node)
          else
            node
          end
        end

        def validate_field_schema!(schema)
          reject_credential_fields!(schema)
          validate_schema_shape!(schema)
        end

        def reject_credential_fields!(schema)
          properties = schema['properties']
          return unless properties.is_a?(Hash)

          properties.each_key do |name|
            next unless ServerConfig.credential_env_name?(name.to_s)

            raise ToolPolicyError,
                  'an MCP server requested a credential-shaped field; the elicitation was rejected'
          end
        end

        def validate_schema_shape!(schema)
          MCP::Tool::InputSchema.new(schema)
        rescue ArgumentError
          raise ToolPolicyError,
                'an MCP server returned an elicitation request with an invalid schema'
        end

        def bounded_message(value)
          BoundedText.bound(value, MAX_MESSAGE_BYTES)
        end
      end
      private_constant :Fields
    end
  end
end
