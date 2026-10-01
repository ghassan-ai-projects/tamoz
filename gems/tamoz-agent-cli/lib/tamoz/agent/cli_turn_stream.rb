# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module Agent
    class CLI
      # Runs one durable step on a worker thread and renders its stream parts to
      # the operator as they arrive.
      class TurnStream
        FAILURE_MESSAGE = 'The session could not complete safely. Please inspect it before retrying.'
        HUMAN_MODES = %i[tasks updates interrupts checkpoints errors].freeze

        # Never reset: the drain loop's empty poll after a failing run must not
        # erase the reason the operator just saw.
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
          # The bounded failure below is delivered through worker.value, not by
          # letting the thread report: a dying thread dumps the backtrace on
          # stderr ahead of the clean message.
          worker = Thread.new do
            Thread.current.report_on_exception = false
            step(sink) { yield context }
          end
          render_parts(sink, worker)
          worker.value
        end

        private

        def build_context(sink, cancellation, thread_id:, request_id:)
          emitter = Tamoz::Graph::StreamEmitter.new(sink:, mode: @json ? :all : HUMAN_MODES)
          Tamoz::Context.new(run_id: request_id, execution_id: SecureRandom.uuid, request_id:, thread_id:,
                             cancellation:, emitter:)
        end

        # Bounded failure by contract (test_durable_worker_checkpoint_conflict_is_a_bounded_failure);
        # the conflict rides as the cause.
        def step(sink)
          yield
        rescue Tamoz::CheckpointConflictError
          raise Tamoz::Agent::Error, FAILURE_MESSAGE
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

        # The error class names a failure whose safe message is generic.
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
