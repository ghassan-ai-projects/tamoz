# frozen_string_literal: true

require 'json'
require 'time'

module Tamoz
  module Agent
    # A stdio MCP server whose three read-only tools let an investigation read this runtime's own record.
    class SelfObserveServer
      DAY_SECONDS = 86_400
      WINDOW = {
        'type' => 'object', 'additionalProperties' => false,
        'properties' => { 'from' => { 'type' => 'string', 'format' => 'date-time' },
                          'until' => { 'type' => 'string', 'format' => 'date-time' } }
      }.freeze
      TOOLS = {
        'diagnose' => [
          'Findings about this Tamoz runtime between from and until (ISO 8601; default the last 24 hours): ' \
          'every rule that fired, its evidence rows, and per-operation counts and latencies.', WINDOW
        ],
        'timeline' => [
          'Ordered events between from and until: turns requested and ended, failed or unknown effect attempts ' \
          'with their error class and code, approvals asked and answered, pauses, logged worker errors.', WINDOW
        ],
        'explain_turn' => [
          'The decision record of one thread (or one request): its executions, every model and tool effect ' \
          'with attempts and failures, and the approvals with who answered them.',
          { 'type' => 'object', 'additionalProperties' => false, 'required' => ['thread_id'],
            'properties' => { 'thread_id' => { 'type' => 'string', 'maxLength' => 128 },
                              'request_id' => { 'type' => 'string', 'maxLength' => 128 } } }
        ]
      }.freeze

      def initialize(runtime_dir:, session_dir:, clock: -> { Time.now })
        @runtime_dir = runtime_dir
        @session_dir = session_dir
        @clock = clock
      end

      def serve
        server = mcp_server
        MCP::Server::Transports::StdioTransport.new(server).open
      end

      def mcp_server
        require 'mcp'
        MCP::Server.new(name: 'tamoz-self-observe', version: CLI::VERSION, tools: TOOLS.keys.map { |name| tool(name) })
      end

      def call(name, arguments)
        arguments = arguments.transform_keys(&:to_s)
        [JSON.generate(answer(name, arguments)), false]
      rescue SelfObservation::Error, ArgumentError, KeyError => e
        [Tamoz::Core.scrub_secrets(e.message), true]
      end

      private

      def tool(name)
        description, schema = TOOLS.fetch(name)
        server = self
        MCP::Tool.define(name:, description:, input_schema: schema,
                         annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true,
                                        open_world_hint: false }) do |**arguments|
          text, error = server.call(name, arguments)
          MCP::Tool::Response.new([{ type: 'text', text: }], error:)
        end
      end

      def answer(name, arguments)
        observation = SelfObservation.open(runtime_dir: @runtime_dir, session_dir: @session_dir)
        return observation.explain(thread: arguments.fetch('thread_id'), request: arguments['request_id']) if
          name == 'explain_turn'

        since_ms, until_ms = window(arguments)
        return observation.timeline(since_ms:, until_ms:) if name == 'timeline'

        observation.diagnose(now_ms: until_ms, since_ms:).to_h
      end

      def window(arguments)
        until_time = arguments['until'] ? Time.iso8601(arguments['until']) : @clock.call
        from_time = arguments['from'] ? Time.iso8601(arguments['from']) : until_time - DAY_SECONDS
        raise ArgumentError, 'from must be before until' unless from_time < until_time

        [(from_time.to_f * 1000).to_i, (until_time.to_f * 1000).to_i]
      end
    end
  end
end
