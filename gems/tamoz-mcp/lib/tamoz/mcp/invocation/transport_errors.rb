# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      # Classifies transport failures without guessing whether an effect occurred.
      class TransportErrors
        def corruption?(error)
          error.is_a?(MCP::Client::RequestHandlerError) &&
            error.original_error.is_a?(JSON::ParserError)
        end

        def stderr_metadata(supervisor)
          { stderr_tail: supervisor.stderr_tail }
        end

        def raise_classified_transport(descriptor, supervisor, error, sent:)
          raise corruption_error(descriptor, supervisor) if corruption?(error)
          raise post_send_transport_error(descriptor, supervisor, sent: sent) if sent

          raise pre_send_unavailable_error(descriptor, supervisor)
        end

        def corruption_error(descriptor, supervisor)
          ToolPolicyError.new(
            "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
            "malformed frames for #{descriptor.id}; the protocol contract was broken",
            **stderr_metadata(supervisor)
          )
        end

        def malformed_response_error(descriptor)
          ToolPolicyError.new(
            "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
            "malformed response for #{descriptor.id}"
          )
        end

        def post_send_transport_error(descriptor, supervisor, sent:)
          return read_only_unavailable_error(descriptor, supervisor) if descriptor.read_only?

          ambiguous_outcome_error(descriptor, supervisor)
        end

        def read_only_unavailable_error(descriptor, supervisor)
          UnavailableError.new(
            "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed " \
            "after the request to #{descriptor.id} was sent; the call is read-only " \
            'and may be retried by the caller',
            **stderr_metadata(supervisor)
          )
        end

        def ambiguous_outcome_error(descriptor, supervisor)
          AmbiguousOutcomeError.new(
            "the MCP server #{descriptor.source_id} failed after the request to " \
            "#{descriptor.id} was sent; the effect is unknown and must not be guessed",
            **stderr_metadata(supervisor)
          )
        end

        def pre_send_unavailable_error(descriptor, supervisor)
          ToolArgumentError.new(
            "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed " \
            "before the request to #{descriptor.id} was sent; no effect occurred",
            **stderr_metadata(supervisor)
          )
        end

        def remote_tool_error(descriptor, code)
          if code.nil?
            ToolArgumentError.new(
              "#{REMOTE_ERROR_PREFIX}: the MCP server #{descriptor.source_id} declared a " \
              "failure for #{descriptor.id}"
            )
          else
            ToolArgumentError.new(
              "#{REMOTE_ERROR_PREFIX}: the MCP server #{descriptor.source_id} rejected the " \
              "call to #{descriptor.id} with error code #{code}"
            )
          end
        end
      end
      private_constant :TransportErrors
    end
  end
end
