# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"
require "tamoz/stream/episode_stream"
require "tamoz/stream/decision_builder"
require "json"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T1.3' + T1.4 (PLAN_TAMOZ_STREAM_BUILD): the episode request origin — the
    # 4th durable request origin after user turns, scheduled occurrences, and
    # channel messages.
    #
    # An episode arrives as a gRPC EpisodeRequest and is validated before
    # anything runs: contract major, identity (episode_id, attempt_id, fence),
    # kind (DIAGNOSE/RECONSIDER), lane (fast/deep/batch), and the risk ceiling.
    # The snapshot digest is verified by ReceivedSnapshot. The capability
    # token is OPAQUE — the stream's EvidenceTools verifies it (CONTRACTS §11
    # as implemented); the worker only carries it for evidence calls (T3).
    #
    # Fencing (invariant 4): the durable request id embeds
    # (episode_id, attempt_id, fence), so a fence+1 redispatch is a NEW
    # request — it never dedupes against an in-flight old attempt, and a
    # redelivered attempt is idempotent on the SAME id.
    class EpisodeRequestEnvelope
      PROTOCOL_VERSION = "1.0"

      KIND_NAMES = {
        EPISODE_KIND_DIAGNOSE: :diagnose,
        EPISODE_KIND_RECONSIDER: :reconsider
      }.freeze
      LANE_NAMES = {
        EPISODE_LANE_FAST: "fast",
        EPISODE_LANE_DEEP: "deep",
        EPISODE_LANE_BATCH: "batch"
      }.freeze
      RISK_NAMES = {
        RISK_CLASS_R0: "r0",
        RISK_CLASS_R1: "r1",
        RISK_CLASS_R2: "r2",
        RISK_CLASS_R3: "r3",
        RISK_CLASS_R4: "r4"
      }.freeze

      def initialize(wire, worker)
        @wire = wire
        @worker = worker
        validate!
      end

      attr_reader :wire

      def episode_id = @wire.episode_id
      def attempt_id = @wire.attempt_id
      def fence = @wire.fence
      def tenant_id = @wire.tenant_id
      def kind = KIND_NAMES.fetch(@wire.kind)
      def lane = LANE_NAMES.fetch(@wire.lane)
      def risk_ceiling = RISK_NAMES.fetch(@wire.risk_ceiling)
      def capability_token = @wire.capability_token

      # The durable request identity. The fence is part of the id, so a
      # superseded attempt (fence+1) is never confused with the in-flight one.
      def request_id
        "episode.#{episode_id}.#{attempt_id}.#{fence}"
      end

      def thread_id
        "episode.#{episode_id}"
      end

      def namespace
        [tenant_id]
      end

      # The durable payload the graph executes against. The episode metadata
      # nests under one declared channel ("episode") and the runner injects the
      # verified snapshot under "snapshot" after ReceivedSnapshot passes; the
      # capability token stays opaque.
      def payload
        {
          "episode" => {
            "episode_id" => episode_id,
            "attempt_id" => attempt_id,
            "fence" => fence,
            "kind" => kind.to_s,
            "lane" => lane,
            "risk_ceiling" => risk_ceiling,
            "tenant_id" => tenant_id,
            "situation_id" => @wire.situation_id,
            "situation_version" => @wire.situation_version,
            "capability_token" => capability_token,
            "evidence_tools_endpoint" => @wire.evidence_tools_endpoint,
            "allowed_intent_types" => @wire.allowed_intent_types.to_a.freeze,
            "supersession_key" => @wire.supersession_key,
            "cancellation_key" => @wire.cancellation_key,
            "snapshot_json" => @wire.snapshot_json,
            "snapshot_sha256" => @wire.snapshot_sha256
          }.freeze
        }.freeze
      end

      # The T0.5 lane → model-tier mapping, applied from config.
      def model_identifier
        @worker.lane_config.model_for(lane)
      end

      private

      def validate!
        unless @wire.protocol_version == PROTOCOL_VERSION
          raise ContractMismatchError,
                "unsupported episode protocol version #{@wire.protocol_version.inspect}"
        end
        if @wire.episode_id.empty? || @wire.attempt_id.empty?
          raise EpisodeRequestInvalidError,
                "episode identity is incomplete (episode_id and attempt_id required)"
        end
        # The ids are joined with "." into the durable request id; a dot in
        # either id would alias different (episode, attempt) pairs. The fence
        # guarantee depends on an unambiguous join.
        if @wire.episode_id.include?(".") || @wire.attempt_id.include?(".")
          raise EpisodeRequestInvalidError,
                "episode_id and attempt_id must not contain '.'"
        end
        if @wire.tenant_id.empty?
          raise EpisodeRequestInvalidError, "tenant_id is required"
        end
        unless @wire.fence.is_a?(Integer) && @wire.fence >= 1
          raise EpisodeRequestInvalidError,
                "episode fence must be a positive integer"
        end
        unless KIND_NAMES.key?(@wire.kind)
          raise EpisodeRequestInvalidError,
                "unsupported episode kind #{@wire.kind.inspect}"
        end
        unless LANE_NAMES.key?(@wire.lane)
          raise EpisodeRequestInvalidError,
                "unsupported episode lane #{@wire.lane.inspect}"
        end
        unless RISK_NAMES.key?(@wire.risk_ceiling)
          raise EpisodeRequestInvalidError,
                "unsupported risk ceiling #{@wire.risk_ceiling.inspect}"
        end

        true
      end
    end

    # T1.4: runs one episode as a durable request through the durable runner —
    # enqueued under the fenced id, executed inside the non-interactive
    # containment context, so a crash mid-episode resumes from a checkpoint
    # and a redelivery is idempotent. The wire event stream (T2.1) turns the
    # run into EpisodeEvent payloads; the runner here returns the durable
    # RequestRecord.
    class EpisodeRunner
      def initialize(durable_runner:, worker:)
        @durable_runner = durable_runner
        @worker = worker
      end

      attr_reader :worker

      def run(wire_request, call = nil)
        Enumerator.new do |yielder|
          envelope = nil
          stream = nil
          adapter = nil
          watcher = nil
          begin
            envelope = EpisodeRequestEnvelope.new(wire_request, @worker)
            snapshot = ReceivedSnapshot.verify(
              wire_request.snapshot_json, wire_request.snapshot_sha256
            )
            stream = EpisodeStream.new(
              envelope, worker_name: @worker&.worker_name, worker_version: @worker&.worker_version
            )
            adapter = EpisodeStreamAdapter.new(stream, budget: wire_request.budget)
            stream.started
            context = Tamoz::Context.new(
              run_id: envelope.request_id,
              execution_id: "episode.#{envelope.episode_id}.#{envelope.attempt_id}.#{envelope.fence}",
              request_id: envelope.request_id,
              interrupt_mode: :non_interactive,
              emitter: adapter
            )
            watcher = watch_cancellation(call, context)
            result = @durable_runner.deliver(
              envelope.payload.merge("snapshot" => snapshot),
              thread: envelope.thread_id,
              request_id: envelope.request_id,
              operation: :turn,
              delivery: :queue,
              namespace: envelope.namespace,
              context:
            )
            status, reason = adapter.terminal_status(result)
            if status == :TERMINAL_STATUS_PRODUCED
              emit_decision(stream, envelope, snapshot, wire_request, result)
            end
            stream.terminal(status, reason_code: reason, usage: adapter.wire_usage)
          rescue Tamoz::Stream::StreamError => error
            # A refused episode still terminates the wire stream with a typed
            # FAILED terminal — never a bare RPC error, and never a model call.
            stream ||= EpisodeStream.new(identity_for(wire_request))
            stream.diagnostic(code: error.class::CATEGORY, message: error.message)
            stream.terminal(:TERMINAL_STATUS_FAILED, reason_code: error.class::CATEGORY)
          rescue StandardError => error
            # ANY other failure terminates the stream typed — the "exactly one
            # terminal" contract holds even when the builder misbehaves.
            stream ||= EpisodeStream.new(identity_for(wire_request))
            stream.diagnostic(code: "internal_error", message: error.class.name)
            stream.terminal(:TERMINAL_STATUS_FAILED, reason_code: "internal_error")
          ensure
            watcher&.kill
          end
          stream.events.each { |event| yielder << event }
        end
      end

      private

      # The failure path has no valid envelope, but the wire stream still needs
      # the episode identity for every event.
      def identity_for(wire_request)
        Struct.new(:episode_id, :attempt_id, :fence).new(
          wire_request.episode_id, wire_request.attempt_id, wire_request.fence
        )
      end

      # T2.4: a completed episode proposes a typed Decision (built from the
      # graph's terminal state) BEFORE the PRODUCED terminal — the stream
      # refuses a produced episode without one. The checkpoint is the request's
      # OWN terminal checkpoint (never the thread's `latest`, which a
      # concurrent fence+1 redispatch could have moved past).
      def emit_decision(stream, envelope, snapshot, wire_request, result)
        return unless result.checkpoint_id

        checkpoint = @durable_runner.compiled.checkpointer.find(
          thread_id: envelope.thread_id,
          namespace: envelope.namespace,
          checkpoint_id: result.checkpoint_id
        )
        outcome = checkpoint.state.to_h
        decision, digest = DecisionBuilder.build(
          envelope:, snapshot:,
          snapshot_digest: wire_request.snapshot_sha256,
          outcome: outcome.transform_keys(&:to_sym)
        )
        stream.decision(
          decision_json: JSON.generate(decision),
          decision_sha256: digest
        )
      end

      # T2.2: an RPC-context cancellation (supersession) cancels the run's
      # token; the executor aborts at its next check, leaving a resumable
      # checkpoint, and the terminal reports CANCELLED.
      def watch_cancellation(call, context)
        return nil unless call&.respond_to?(:cancelled?)

        Thread.new do
          loop do
            break if call.cancelled? || context.cancellation.cancelled?

            sleep 0.1
          end
          context.cancellation.cancel!("rpc cancelled") unless
            context.cancellation.cancelled?
        end
      end
    end
  end
end
