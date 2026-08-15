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

      def model_started(ordinal:, provider:, model_id:, request_sha256: nil)
        build do |event|
          event.model_started = Agenticstream::Runtime::V1::ModelStarted.new(
            ordinal:, provider:, model_id:,
            request_sha256: Tamoz::Core.digest_bytes(request_sha256)
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

      def model_completed(ordinal:, usage: nil, response_sha256: nil, finish_reason: "stop")
        build do |event|
          event.model_completed = Agenticstream::Runtime::V1::ModelCompleted.new(
            ordinal:, finish_reason:,
            usage:,
            response_sha256: Tamoz::Core.digest_bytes(response_sha256)
          )
        end
      end

      def tool(call_id:, tool_name:, state:, arguments_sha256: nil, result_sha256: nil,
               is_error: false, execution_started: nil, error_code: nil)
        build do |event|
          event.tool = Agenticstream::Runtime::V1::ToolLifecycle.new(
            call_id:, tool_name:, state:,
            arguments_sha256: Tamoz::Core.digest_bytes(arguments_sha256),
            result_sha256: Tamoz::Core.digest_bytes(result_sha256),
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
            decision_sha256: Tamoz::Core.digest_bytes(decision_sha256),
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

    # P1/§8.2: the wire projection boundary. Two channels, one EpisodeStream:
    #
    #   - `emit` is the graph Context emitter entry (type, namespace, data,
    #     run_id, task_id). It REJECTS model event types — a node can never
    #     produce a model event (B4); the runner produces them from verified
    #     journal receipts through `emit_stream_part`.
    #   - `emit_stream_part` is the trusted channel: model events from
    #     journal-verified receipts.
    #
    # Event counters, the budget state machine, and budget-aware terminal
    # mapping are gone (P1); budgets return in P2 computed from receipts.
    class EpisodeStreamAdapter
      MODEL_EVENT_TYPES = %i[model_started model_delta model_completed].freeze

      TERMINAL_BY_RESULT = {
        completed: :TERMINAL_STATUS_PRODUCED,
        failed: :TERMINAL_STATUS_FAILED,
        cancelled: :TERMINAL_STATUS_CANCELLED,
        paused: :TERMINAL_STATUS_FAILED
      }.freeze

      def initialize(stream)
        @stream = stream
      end

      attr_reader :stream

      # The Context emitter entry point. Model events are forbidden here — the
      # only model events on the wire come from receipts via the trusted
      # channel. A node attempt is a typed failure, never a silent drop.
      def emit(type, namespace, data = {}, run_id: nil, task_id: nil)
        type_sym = type.to_sym
        if MODEL_EVENT_TYPES.include?(type_sym)
          raise StreamError,
                "graph node attempted to emit forbidden model event #{type_sym}"
        end

        case type_sym
        when :error then diagnostic(data)
        else nil # checkpoint/interrupt/node_update/task events stay internal
        end
      end

      # The trusted channel: StreamParts produced from journal-verified
      # receipts. This is the only path that crosses model events.
      # Decision/terminal events are runner-owned translations of the terminal
      # state (not journal receipts), so the runner emits them directly.
      def emit_stream_part(part)
        case part.type
        when :model_started
          @stream.model_started(
            ordinal: Integer(part.data.fetch("ordinal")),
            provider: String(part.data.fetch("provider")),
            model_id: String(part.data.fetch("model_id")),
            request_sha256: part.data["request_sha256"]
          )
        when :model_completed
          @stream.model_completed(
            ordinal: Integer(part.data.fetch("ordinal")),
            usage: wire_usage(part.data["usage"]),
            response_sha256: part.data["response_sha256"]
          )
        else
          nil
        end
      end

      # The terminal status from the durable run result only — no budget
      # overrides (P1; receipts-based budgets return in P2).
      def terminal_status(result)
        TERMINAL_BY_RESULT.fetch(result&.status, :TERMINAL_STATUS_FAILED)
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

      private

      # nil usage (unavailable) crosses as nil — the wire claims nothing it
      # cannot prove. Present usage is mapped 1:1 from the receipt projection.
      def wire_usage(usage)
        return nil if usage.nil?

        Agenticstream::Runtime::V1::Usage.new(
          input_tokens: Integer(usage.fetch("input_tokens", 0)),
          output_tokens: Integer(usage.fetch("output_tokens", 0)),
          cached_input_tokens: Integer(usage.fetch("cached_input_tokens", 0)),
          reasoning_tokens: Integer(usage.fetch("reasoning_tokens", 0)),
          cost_microunits: Integer(usage.fetch("cost_microunits", 0))
        )
      end
    end
  end
end
