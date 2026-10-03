# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      # Opens a supervised channel only for the session-pinned capability.
      class Channel
        def verify_pinned_digest!(descriptor, snapshot)
          raise ValidationError, 'snapshot must be a Tamoz::Mcp::Catalog snapshot' unless snapshot.respond_to?(:entries)

          entry = snapshot.entries.find { |candidate| candidate.name == descriptor.name }
          unless entry && entry.definition_digest == descriptor.definition_digest
            raise CatalogSnapshotUnavailableError,
                  "the definition digest for #{descriptor.id} does not match the " \
                  'pinned catalog snapshot; no request was sent'
          end
          nil
        end

        def open_pinned_channel(descriptor, snapshot:, supervisor:, client_factory:)
          verify_pinned_digest!(descriptor, snapshot)
          ensure_available!(descriptor, supervisor)

          client = build_client(supervisor, client_factory)
          ensure_connected!(descriptor, client, supervisor)
          client
        end

        def ensure_available!(descriptor, supervisor)
          case supervisor.state
          when :open
            raise UnavailableError,
                  "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} circuit is " \
                  "open after #{supervisor.circuit_threshold} consecutive transport failures"
          when :retired
            raise UnavailableError,
                  "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} is retired"
          end
          nil
        end

        def build_client(supervisor, client_factory)
          factory = client_factory || ->(sup) { MCP::Client.new(transport: sup) }
          client = factory.call(supervisor)
          raise ValidationError, 'client_factory must return an MCP client' unless client.respond_to?(:call_tool)

          client
        end

        def ensure_connected!(descriptor, client, supervisor)
          return if supervisor.connected?

          supervisor.start unless supervisor.started?
          _min, max = supervisor.config.protocol_range
          begin
            ::Timeout.timeout(supervisor.config.budgets.connect_timeout) do
              client.connect(client_info: CLIENT_INFO, protocol_version: max)
            end
          rescue ::Timeout::Error, MCP::Client::RequestHandlerError,
                 MCP::Client::ServerError, MCP::Client::ValidationError => e
            raise handle_handshake_failure(descriptor, supervisor, e)
          end
          nil
        end

        def handle_handshake_failure(descriptor, supervisor, error)
          # §6's corruption row applies to the handshake too: a server that
          # answers initialize with malformed frames broke the protocol
          # contract and must never become a retryable value the planner can
          # iterate on. The corruption is detectable here exactly as in
          # `raise_classified_transport` (RequestHandlerError wrapping a
          # JSON::ParserError); the classification is the fix.
          if TransportErrors.new.corruption?(error)
            supervisor.record_failure(kind: :corruption)
            return ToolPolicyError.new(
              "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
              'malformed frames during the protocol handshake; the protocol ' \
              'contract was broken',
              **TransportErrors.new.stderr_metadata(supervisor)
            )
          end

          supervisor.record_failure(kind: :connect)
          UnavailableError.new(
            "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed to connect",
            **TransportErrors.new.stderr_metadata(supervisor)
          )
        end
      end
      private_constant :Channel
    end
  end
end
