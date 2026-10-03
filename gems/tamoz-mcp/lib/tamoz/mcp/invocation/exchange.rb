# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      # Runs the bounded MCP round trip and its read-only recovery path.
      class Exchange
        def round_trip(descriptor:, arguments:, client:, supervisor:, effect_key:, headless:, url_policy:, input:)
          begin
            response = transport_round_trip(
              descriptor: descriptor, arguments: arguments, client: client,
              supervisor: supervisor, input: input
            )
          rescue MCP::Client::ServerError => e
            supervisor.record_success
            raise TransportErrors.new.remote_tool_error(descriptor, e.code)
          rescue MCP::Client::ValidationError
            supervisor.record_failure(kind: :protocol)
            raise TransportErrors.new.malformed_response_error(descriptor)
          rescue MCP::Client::InputRequiredError => e
            supervisor.record_success
            return interrupt_or_deny(
              descriptor, e,
              effect_key: effect_key, headless: headless, url_policy: url_policy
            )
          end

          Result.new.succeeded_outcome(response, descriptor: descriptor, supervisor: supervisor, effect_key: effect_key)
        end

        def transport_round_trip(descriptor:, arguments:, client:, supervisor:, input:)
          max_attempts = 1 + (descriptor.read_only? ? supervisor.retry_budget : 0)
          attempts = 0
          begin
            response = call_with_deadline(client, descriptor, arguments, supervisor, input)
          rescue Timeout::Error, MCP::Client::RequestHandlerError => e
            attempts += 1
            sent = record_transport_failure(descriptor, supervisor, e)
            # Read-only calls may retry through the supervisor's restart budget;
            # corruption is terminal and never retried. The restart spawns a
            # fresh process, so the transport must be reconnected before retry.
            if retry_eligible?(attempts, max_attempts, descriptor, supervisor, e)
              supervisor.restart
              Channel.new.ensure_connected!(descriptor, client, supervisor)
              retry
            end
            # A timed-out request may still answer on this pipe; the next call must read a fresh one.
            supervisor.restart if e.is_a?(Timeout::Error) && !supervisor.open?
            TransportErrors.new.raise_classified_transport(descriptor, supervisor, e, sent: sent)
          end
          response
        end

        def retry_eligible?(attempts, max_attempts, descriptor, supervisor, error)
          attempts < max_attempts && descriptor.read_only? && !supervisor.open? && !TransportErrors.new.corruption?(error)
        end

        def call_with_deadline(client, descriptor, arguments, supervisor, input)
          ::Timeout.timeout(supervisor.config.budgets.request_timeout) do
            input.nil? ? call_tool(client, descriptor, arguments) : resume_tool(client, descriptor, arguments, input)
          end
        end

        def call_tool(client, descriptor, arguments)
          client.call_tool(name: descriptor.name, arguments: arguments)
        end

        def resume_tool(client, descriptor, arguments, input)
          params = {
            name: descriptor.name,
            arguments: arguments,
            inputResponses: input.fetch('inputResponses')
          }
          state = input['requestState']
          params[:requestState] = state unless state.nil?
          # The SDK's private `request` pipeline: JSON-RPC error raising,
          # `_meta` handling, and `input_required` detection all stay in the
          # official client (P10 §1: never reimplement the protocol).
          client.send(:request, method: 'tools/call', params: params)
        end

        def record_transport_failure(descriptor, supervisor, error)
          sent = supervisor.request_sent?
          kind = if error.is_a?(OutputLimitError)
                   :output_limit
                 elsif TransportErrors.new.corruption?(error)
                   :corruption
                 elsif error.is_a?(Timeout::Error)
                   :timeout
                 else
                   :transport
                 end
          context = {
            'tool_name' => descriptor.name,
            'failure_class' => error.class.name
          }
          supervisor.record_failure(kind: kind, context: context)
          sent
        end

        def denied_outcome(descriptor, effect_key)
          denial = Elicitation.denial(
            server_id: descriptor.source_id,
            capability: descriptor.id,
            reason: 'unattended runs cannot answer an MCP elicitation'
          )
          Outcome.new(
            status: :denied, observation: nil, interrupt: nil,
            denial: denial, effect_key: effect_key
          )
        end

        def interrupt_or_deny(descriptor, error, effect_key:, headless:, url_policy:)
          return denied_outcome(descriptor, effect_key) if headless

          interrupt = Elicitation.build(
            descriptor: descriptor,
            effect_key: effect_key,
            input_requests: error.input_requests,
            request_state: error.request_state,
            url_policy: url_policy
          )
          Outcome.new(
            status: :interrupt, observation: nil, interrupt: interrupt,
            denial: nil, effect_key: effect_key
          )
        end
      end
      private_constant :Exchange
    end
  end
end
