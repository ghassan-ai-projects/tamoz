# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      # Validates, bounds and attributes successful MCP tool results.
      class Result
        def succeeded_outcome(response, descriptor:, supervisor:, effect_key:)
          result = validate_result_shape!(response, descriptor)
          if result['isError'] == true
            supervisor.record_success
            raise TransportErrors.new.remote_tool_error(descriptor, nil)
          end
          validate_structured_content!(result, descriptor)

          # The transport demonstrably worked: a successful round-trip breaks
          # the consecutive-failure streak that feeds the circuit.
          supervisor.record_success

          observation = build_observation(result, descriptor, supervisor)
          Outcome.new(
            status: :succeeded, observation: observation,
            interrupt: nil, denial: nil, effect_key: effect_key
          )
        end

        def validate_result_shape!(response, descriptor)
          unless response.is_a?(Hash) && response['result'].is_a?(Hash)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
                  'response that is not a JSON-RPC success result'
          end

          result = response['result']
          unless result['content'].is_a?(Array)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
                  'tool result without a content array'
          end
          result
        end

        def validate_structured_content!(result, descriptor)
          schema = descriptor.output_schema
          return if schema.nil?
          return if result['structuredContent'].nil?

          begin
            MCP::Tool::OutputSchema.new(schema).validate_result(result['structuredContent'])
          rescue MCP::Tool::OutputSchema::ValidationError, ArgumentError
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
                  "structured content for #{descriptor.id} that violates the declared " \
                  'output schema'
          end
        end

        def build_observation(result, descriptor, supervisor)
          budget = supervisor.config.budgets.max_output_bytes
          blocks, blocks_truncated = attribute_blocks(result['content'], descriptor.source_id, budget)
          structured, structured_truncated = sanitize_structured(result['structuredContent'], budget)
          text = attributed_text(blocks, descriptor.source_id)

          Observation.new(
            server_id: descriptor.source_id,
            content_blocks: blocks,
            text: text,
            structured_content: structured,
            truncated: blocks_truncated || structured_truncated
          )
        end

        def attributed_text(blocks, source_id)
          texts = blocks.filter_map { |block| block['text'] if block['type'] == 'text' }
          return '' if texts.empty?
          return texts.first if texts.length == 1

          attribution = format(ATTRIBUTION_TEMPLATE, source_id)
          texts.map { |text| "#{attribution}: #{text}" }.join("\n")
        end

        def attribute_blocks(content, source_id, budget)
          attribution = format(ATTRIBUTION_TEMPLATE, source_id)
          blocks = []
          truncated = false
          remaining = budget

          content.each do |block|
            break if remaining <= 0

            attributed, remaining, truncated = build_attributed_block(
              block, attribution, source_id, remaining, truncated
            )
            blocks << attributed.freeze
          end

          truncated = true if content.length > blocks.length
          [blocks.freeze, truncated]
        end

        def build_attributed_block(block, attribution, source_id, remaining, truncated)
          unless block.is_a?(Hash)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{source_id} returned a content " \
                  'block that is not an object'
          end

          type = block['type']
          attributed = { 'attribution' => attribution, 'type' => type }
          case type
          when 'text'
            build_text_block(attributed, block, remaining, truncated)
          when 'image'
            build_image_block(attributed, block, remaining, truncated)
          when 'resource'
            build_resource_block(attributed, block, source_id, remaining, truncated)
          else
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{source_id} returned a content " \
                  'block with an unknown type'
          end
        end

        def build_text_block(attributed, block, remaining, truncated)
          text = scrub_text(block['text'].to_s)
          text, remaining, truncated = fit_to_budget(text, remaining, truncated)
          attributed['text'] = text
          [attributed, remaining, truncated]
        end

        def build_image_block(attributed, block, remaining, truncated)
          data = block['data'].to_s
          data, remaining, truncated = fit_to_budget(data, remaining, truncated)
          attributed['data'] = data
          attributed['mimeType'] = scrub_text(block['mimeType'].to_s)[0, 128]
          [attributed, remaining, truncated]
        end

        def build_resource_block(attributed, block, source_id, remaining, truncated)
          resource = block['resource']
          unless resource.is_a?(Hash)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{source_id} returned a resource " \
                  'content block without a resource object'
          end

          uri = scrub_text(resource['uri'].to_s)[0, MAX_STRUCTURED_FIELD_BYTES]
          text = scrub_text(resource['text'].to_s)
          text, remaining, truncated = fit_to_budget(text, remaining, truncated)
          attributed['resource'] = { 'uri' => uri, 'text' => text }
          [attributed, remaining, truncated]
        end

        def fit_to_budget(text, remaining, truncated)
          return [text, remaining - text.bytesize, truncated] if text.bytesize <= remaining

          [truncate_bytes(text, remaining), 0, true]
        end

        def sanitize_structured(structured, budget)
          return [nil, false] if structured.nil?

          copied = strip_controls_deep(structured)
          bytes = CanonicalJSON.dump(copied).bytesize
          return [CanonicalJSON.deep_freeze(copied), false] if bytes <= budget

          [nil, true]
        rescue ValidationError
          [nil, true]
        end

        def strip_controls_deep(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, entry), out| out[key.to_s] = strip_controls_deep(entry) }
          when Array
            value.map { |entry| strip_controls_deep(entry) }
          when String
            scrub_text(value)
          else
            value
          end
        end

        def scrub_text(value)
          text = String(value).dup.force_encoding(Encoding::UTF_8)
          text = text.scrub('') unless text.valid_encoding?
          text.gsub(CONTROL_CHARACTER_PATTERN, ' ')
        end

        def truncate_bytes(text, bytes)
          text.byteslice(0, bytes).scrub('').rstrip
        end
      end
      private_constant :Result
    end
  end
end
