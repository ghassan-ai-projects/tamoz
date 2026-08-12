# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T2.1 (PLAN_TAMOZ_STREAM_BUILD T2.1): the wire event vocabulary. The
    # episode stream builds EpisodeEvent payloads for one episode with the
    # stream's exact contract: sequence 1..N, `(episode_id, attempt_id,
    # fence)` on EVERY event, exactly one terminal, and a decision before a
    # PRODUCED terminal. The graph's internal events stay internal — only
    # this vocabulary crosses.
    class EpisodeStream
      def initialize(envelope, worker_name: nil, worker_version: nil, started_at: nil)
        @envelope = envelope
        @worker_name = worker_name
        @worker_version = worker_version
        @started_at = started_at || Time.now.to_i
        @sequence = 0
        @terminal_emitted = false
        @events = []
      end

      attr_reader :envelope

      def sequence = @sequence
      def terminal_emitted? = @terminal_emitted

      # All built events, in order — the runner yields these to the wire.
      def events = @events

      def started
        build do |event|
          event.started = Agenticstream::Runtime::V1::EpisodeStarted.new(
            worker_name: @worker_name,
            worker_version: @worker_version
          )
        end
      end

      def model_started(ordinal:, provider:, model_id:)
        build do |event|
          event.model_started = Agenticstream::Runtime::V1::ModelStarted.new(
            ordinal:, provider:, model_id:
          )
        end
      end

      def model_delta(ordinal:, content:)
        build do |event|
          event.model_delta = Agenticstream::Runtime::V1::ModelDelta.new(
            model_ordinal: ordinal, lane: :DELTA_LANE_ASSISTANT, text: content
          )
        end
      end

      def model_completed(ordinal:, usage:)
        build do |event|
          event.model_completed = Agenticstream::Runtime::V1::ModelCompleted.new(
            ordinal:, usage:
          )
        end
      end

      def tool(call_id:, tool_name:, state:, arguments_sha256: nil, result_sha256: nil,
               is_error: false, execution_started: nil, error_code: nil)
        build do |event|
          event.tool = Agenticstream::Runtime::V1::ToolLifecycle.new(
            call_id:, tool_name:, state:, arguments_sha256:, result_sha256:,
            is_error:, execution_started:, error_code:
          )
        end
      end

      def budget(remaining: nil, cumulative_usage: nil, model_calls_used: nil, tool_calls_used: nil)
        build do |event|
          event.budget = Agenticstream::Runtime::V1::BudgetUpdated.new(
            remaining:, cumulative_usage:, model_calls_used:, tool_calls_used:
          )
        end
      end

      def decision(decision_json:, decision_sha256:)
        build do |event|
          event.decision = Agenticstream::Runtime::V1::DecisionProposed.new(
            decision_json: decision_json.to_s.b,
            decision_sha256:,
            episode_id: @envelope.episode_id,
            attempt_id: @envelope.attempt_id,
            fence: @envelope.fence
          )
        end
      end

      def diagnostic(code:, message:, retryable: false)
        build do |event|
          event.diagnostic = Agenticstream::Runtime::V1::Diagnostic.new(
            code:, message:, retryable:
          )
        end
      end

      def cancelling(reason_code:, deadline: nil)
        build do |event|
          event.cancelling = Agenticstream::Runtime::V1::EpisodeCancelling.new(
            reason_code:, deadline:
          )
        end
      end

      # Exactly one terminal per episode; a second call raises. T2.3: a
      # produced episode's terminal carries the artifact manifest (the digests
      # a shadow run needs to reproduce the Decision without re-running
      # Tamoz), and the named artifacts are retained by the runner.
      def terminal(status, reason_code: nil, usage: nil, artifact_manifest: nil)
        if @terminal_emitted
          raise StreamError, "episode stream already emitted its terminal"
        end

        @terminal_emitted = true
        build do |event|
          event.terminal = Agenticstream::Runtime::V1::Terminal.new(
            status:, reason_code:, usage:, artifact_manifest:
          )
        end
      end

      private

      def build
        @sequence += 1
        event = Agenticstream::Runtime::V1::EpisodeEvent.new(
          episode_id: @envelope.episode_id,
          sequence: @sequence,
          occurred_at: timestamp(Time.now.to_i),
          attempt_id: @envelope.attempt_id,
          fence: @envelope.fence
        )
        yield event
        @events << event
        event
      end

      def timestamp(epoch_seconds)
        Google::Protobuf::Timestamp.new(seconds: epoch_seconds)
      end
    end

    # T2.1/T2.2: adapts the graph's Context emitter events and the durable run
    # result to the wire vocabulary, with budget accounting. The graph's
    # internal events (checkpoint/interrupt/node_update) stay internal; only
    # task/model/error events cross. The budget ceiling (model calls, tokens,
    # wall time) turns a run into TIMED_OUT or BUDGET_EXHAUSTED at the
    # terminal instead of a produced Decision.
    class EpisodeStreamAdapter
      TERMINAL_BY_RESULT = {
        completed: :TERMINAL_STATUS_PRODUCED,
        failed: :TERMINAL_STATUS_FAILED,
        cancelled: :TERMINAL_STATUS_CANCELLED,
        paused: :TERMINAL_STATUS_FAILED
      }.freeze

      def initialize(stream, budget: nil)
        @stream = stream
        @budget = budget
        @model_calls = 0
        @tool_calls = 0
        @usage = {
          input_tokens: 0, output_tokens: 0,
          cached_input_tokens: 0, reasoning_tokens: 0, cost_microunits: 0
        }
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      attr_reader :stream

      # The Context emitter entry point (type, namespace, data, run_id,
      # task_id) — namespace is the graph's, never crossed to the wire.
      def emit(type, namespace, data = {}, run_id: nil, task_id: nil)
        case type
        when :task_start then tool_started(data, task_id)
        when :task_end then tool_completed(data, task_id)
        when :model_started then model_started(data)
        when :model_delta then model_delta(data)
        when :model_completed then model_completed(data)
        when :error then diagnostic(data)
        end
      end

      def tool_started(data, task_id)
        name = data.fetch("node")
        @tool_calls += 1
        @stream.tool(call_id: task_id, tool_name: name, state: :TOOL_STATE_REQUESTED)
        @stream.tool(call_id: task_id, tool_name: name, state: :TOOL_STATE_STARTED)
      end

      def tool_completed(data, task_id)
        @stream.tool(
          call_id: task_id, tool_name: data.fetch("node"),
          state: :TOOL_STATE_COMPLETED
        )
      end

      def model_started(data)
        @stream.model_started(
          ordinal: data[:ordinal],
          provider: data[:provider].to_s,
          model_id: data[:model_id].to_s
        )
      end

      def model_delta(data)
        @stream.model_delta(ordinal: data[:ordinal], content: data[:content].to_s)
      end

      def model_completed(data)
        @model_calls += 1
        enforce_mid_run_budget!
        accumulate(data[:usage] || {})
        @stream.model_completed(ordinal: data[:ordinal], usage: wire_usage)
        emit_budget
      end

      # The graph error event carries the ORIGINAL error class (the adapter
      # owns the safe-message disclosure). When that class is a Tamoz error
      # with a typed category — the non-interactive interrupt, for instance —
      # the category crosses the wire instead of a generic graph_step_failed,
      # so a consumer can act on the real reason.
      def diagnostic(data)
        code = typed_code(data["error_class"].to_s)
        @stream.diagnostic(
          code:,
          message: data.fetch("safe_message", "graph step failed"),
          retryable: false
        )
      end

      def typed_code(error_class_name)
        return "graph_step_failed" unless error_class_name.start_with?("Tamoz::")

        klass = error_class_name.split("::").reduce(Object) do |acc, part|
          acc.const_get(part, false)
        end
        return "graph_step_failed" unless klass.const_defined?(:CATEGORY, false)

        klass::CATEGORY
      rescue NameError
        "graph_step_failed"
      end

      def emit_budget
        @stream.budget(
          model_calls_used: @model_calls,
          tool_calls_used: @tool_calls,
          cumulative_usage: wire_usage
        )
      end

      # The terminal for the durable run result, budget-aware (T2.2). The
      # decision event (T2.4) is emitted by the caller before this terminal.
      def terminal(result)
        status, reason = terminal_status(result)
        @stream.terminal(status, reason_code: reason, usage: wire_usage)
      end

      def terminal_status(result)
        base = TERMINAL_BY_RESULT.fetch(result&.status, :TERMINAL_STATUS_FAILED)
        return [:TERMINAL_STATUS_TIMED_OUT, "wall_time"] if wall_time_exceeded?
        return [:TERMINAL_STATUS_BUDGET_EXHAUSTED, "max_model_calls"] if model_calls_exceeded?

        [base, nil]
      end

      def wall_time_exceeded?
        return false unless @budget&.respond_to?(:wall_time) && @budget.wall_time

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
        elapsed > @budget.wall_time.seconds
      end

      def model_calls_exceeded?
        return false unless @budget&.respond_to?(:max_model_calls) && @budget.max_model_calls&.positive?

        @model_calls > @budget.max_model_calls
      end

      # F-2: a ceiling crossed MID-RUN aborts the run (the raise fails the
      # graph node and the episode terminates typed) instead of only labelling
      # the terminal after the spend happened.
      def enforce_mid_run_budget!
        return if @budget.nil?

        if model_calls_exceeded?
          raise BudgetExceededError,
                "model call budget exhausted at #{@model_calls} calls"
        end
        if wall_time_exceeded?
          raise BudgetExceededError, "episode wall time budget exhausted"
        end
      end

      private

      def accumulate(usage)
        %i[input_tokens output_tokens cached_input_tokens reasoning_tokens cost_microunits].each do |key|
          @usage[key] += usage[key].to_i
        end
      end

      def wire_usage
        Agenticstream::Runtime::V1::Usage.new(**@usage)
      end
      public :wire_usage
    end
  end
end
