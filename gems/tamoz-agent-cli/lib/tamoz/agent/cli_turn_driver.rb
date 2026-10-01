# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module Agent
    class CLI
      # Drives one durable thread from the terminal: delivers the turn, then keeps
      # advancing queued requests, answering interrupts and continuing until the
      # thread settles or waits on the operator, and reports how it ended.
      class TurnDriver
        include CLIRendering

        UNSETTLED = %i[paused running].freeze

        def initialize(session, thread_id:, owner_id:, options:, operator:)
          @session = session
          @thread_id = thread_id
          @owner_id = owner_id
          @options = options
          @out = operator.out
          @err = operator.err
          @events = operator.events
          @stream = TurnStream.new(operator, json: options[:json])
          @answers = InterruptAnswers.new(operator, options)
          @rendered_stale_request_ids = {}
        end

        def turn(task, request_id:)
          operation = @options[:research] ? :research : :start
          @stream.run(thread_id: @thread_id, request_id:) do |context|
            @session.public_send(operation, task, thread: @thread_id, request_id:, owner_id: @owner_id, context:)
          end
          exit_for_view(drain)
        end

        def resume(request_id:, resume_options:)
          view = current_view
          case view.status
          when :paused
            answers = @answers.resolve(view, resume_options)
            return CLI::EXIT_PAUSED if answers.nil?

            resume_with(answers, request_id)
          when :running then continue_with(request_id)
          when :blocked then return report_blocked(view.blocked || {})
          else return report_settled(view)
          end
          exit_for_view(drain(resume_options:))
        end

        def continue(request_id:)
          continue_with(request_id)
          exit_for_view(drain)
        end

        def drain(tracked_request: nil, resume_options: {})
          loop do
            render_pending_stale_failures
            if tracked_request && queued_behind?(tracked_request)
              report_queued(current_view)
              return current_view
            end
            next if advance_queued_request

            case advance_turn(resume_options)
            when :waiting then return current_view
            when :settled then break
            end
          end
          current_view.tap { |view| render_final_view(view, options: @options, stream_error: @stream.error) }
        end

        private

        def current_view = @session.view(thread: @thread_id)

        def emit_cli_event(type, data) = @events.emit(type, data)

        def queued?(request)
          current = @session.app.durable_runner.fetch(thread: request.thread_id, request_id: request.request_id)
          current&.status == :queued
        end

        def report_queued(view)
          front_request_id = view.execution_id
          if @options[:json]
            emit_cli_event('cli.paused', { 'reason' => 'queued', 'thread_id' => @thread_id,
                                           'behind_request_id' => front_request_id })
          else
            @err.puts "Follow-up queued behind request #{front_request_id} (status: #{view.status})."
            @err.puts "Run `tamoz resume #{@thread_id}` to advance."
          end
        end

        def queued_behind?(tracked_request)
          queued?(tracked_request) && UNSETTLED.include?(current_view.status)
        end

        def advance_turn(resume_options)
          view = current_view
          case view.status
          when :paused then answer_interrupts(view, resume_options)
          when :running
            continue_with(SecureRandom.uuid)
            :delivered
          else :settled
          end
        end

        def answer_interrupts(view, resume_options)
          return :waiting if view.interrupts.empty?

          answers = @answers.resolve(view, resume_options)
          return :waiting if answers.nil?

          resume_with(answers, SecureRandom.uuid)
          :delivered
        end

        def resume_with(answers, request_id)
          @stream.run(thread_id: @thread_id, request_id:) do |context|
            @session.resume(answers, thread: @thread_id, request_id:, owner_id: @owner_id, context:)
          end
        end

        def continue_with(request_id)
          @stream.run(thread_id: @thread_id, request_id:) do |context|
            @session.continue(thread: @thread_id, request_id:, owner_id: @owner_id, context:)
          end
        end

        # A stale request is terminal-failed by run_next; render its typed reason
        # once and keep draining — a failed request is never re-claimed (DR-4 D3).
        def advance_queued_request
          advanced = @stream.run(thread_id: @thread_id, request_id: SecureRandom.uuid) do |context|
            @session.app.durable_runner.run_next(thread: @thread_id, owner_id: @owner_id, context:)
          end
          render_request_terminal_failure(advanced) if advanced&.stale_failure?
          advanced
        end

        def report_blocked(blocked)
          if @options[:json]
            emit_cli_event('cli.paused', { 'reason' => 'blocked', 'thread_id' => @thread_id, 'blocked' => blocked })
          else
            @err.puts "Thread is blocked on effect #{blocked.fetch('effect_key', 'unknown')}."
            @err.puts "Resolve it with: tamoz resolve #{@thread_id} EFFECT_KEY {succeeded|failed|abandoned}"
          end
          CLI::EXIT_PAUSED
        end

        def report_settled(view)
          render_show(view, thread_id: @thread_id, transcript: 50, json: @options[:json])
          exit_for_view(view)
        end

        # A `deliver` inside session.resume/start/continue can terminal-fail a
        # stale request the drain loop never sees; each is rendered once.
        def render_pending_stale_failures
          @session.app.durable_runner.history(thread: @thread_id).each do |request|
            next unless request.stale_failure?
            next if @rendered_stale_request_ids.key?(request.request_id)

            render_request_terminal_failure(request)
          end
        end

        def render_request_terminal_failure(request)
          @rendered_stale_request_ids[request.request_id] = true
          reason = request.terminal_error.fetch('reason')
          if @options[:json]
            emit_cli_event('cli.request_stale', { 'thread_id' => request.thread_id, 'request_id' => request.request_id,
                                                  'operation' => request.operation.to_s, 'reason' => reason })
          else
            @err.puts "tamoz: stale #{request.operation} request #{request.request_id} was not run: #{reason}"
          end
        end
      end
    end
  end
end
