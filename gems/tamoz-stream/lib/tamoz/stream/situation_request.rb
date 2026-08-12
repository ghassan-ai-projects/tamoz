# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"

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

      def run(wire_request, _call = nil)
        envelope = EpisodeRequestEnvelope.new(wire_request, @worker)
        snapshot = ReceivedSnapshot.verify(
          wire_request.snapshot_json, wire_request.snapshot_sha256
        )
        context = Tamoz::Context.new(
          run_id: envelope.request_id,
          execution_id: "episode.#{envelope.episode_id}.#{envelope.attempt_id}.#{envelope.fence}",
          request_id: envelope.request_id,
          interrupt_mode: :non_interactive
        )
        @durable_runner.deliver(
          envelope.payload.merge("snapshot" => snapshot),
          thread: envelope.thread_id,
          request_id: envelope.request_id,
          operation: :turn,
          delivery: :queue,
          namespace: envelope.namespace,
          context:
        )
      end
    end
  end
end
