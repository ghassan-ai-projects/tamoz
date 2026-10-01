# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module Agent
    class CLI
      # Runs one durable step and renders its stream parts.
      class TurnStream
        FAILURE_MESSAGE = 'The session could not complete safely. Please inspect it before retrying.'
        HUMAN_MODES = %i[tasks updates interrupts checkpoints errors].freeze

        attr_reader :error

        def initialize(operator, json:)
          @events = operator.events
          @err = operator.err
          @cancellation = operator.cancellation
          @json = json
          @error = nil
        end

        def run(thread_id:, request_id:)
          cancellation = @cancellation || Tamoz::CancellationToken.new
          sink = Tamoz::StreamSink.new(cancellation:, run_id: request_id)
          context = build_context(sink, cancellation, thread_id:, request_id:)
          worker = Thread.new { step(sink) { yield context } }
          render_parts(sink, worker)
          outcome = worker.value
          raise Tamoz::Agent::Error, FAILURE_MESSAGE, cause: outcome if outcome.is_a?(Tamoz::CheckpointConflictError)

          outcome
        end

        private

        def build_context(sink, cancellation, thread_id:, request_id:)
          emitter = Tamoz::Graph::StreamEmitter.new(sink:, mode: @json ? :all : HUMAN_MODES)
          Tamoz::Context.new(run_id: request_id, execution_id: SecureRandom.uuid, request_id:, thread_id:,
                             cancellation:, emitter:)
        end

        def step(sink)
          yield
        rescue Tamoz::CheckpointConflictError => e
          e
        ensure
          sink.finish
        end

        def render_parts(sink, worker)
          sink.each { |part| render_part(part) }
        ensure
          sink.finish unless sink.finished?
          worker.join
        end

        def render_part(part)
          return @events.emit(part.type.to_s, part.data, part) if @json

          data = part.data
          case part.type
          when :custom
            event = Tamoz::Agent::Event.new(type: data['type'].to_sym, data: data.fetch('data', data))
            @events.render(event, json: false)
          when :error
            @error = error_summary(data)
            @err.puts "Error: #{@error}"
          end
        end

        def error_summary(data)
          reason = data['safe_message'].to_s.strip
          reason = 'the session failed' if reason.empty?
          node = data['node'].to_s.strip
          where = [node.empty? ? nil : "node #{node}", data['error_class'].to_s.strip].reject { _1.nil? || _1.empty? }
          where.empty? ? reason : "#{reason} (#{where.join(', ')})"
        end
      end
    end
  end
end
