# frozen_string_literal: true

require "tamoz/stream/gen"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T1.2 (PLAN_TAMOZ_STREAM_BUILD T1.2): the EpisodeWorker gRPC service.
    # The worker is the SERVER: the stream's WorkerExecutor dials it over UDS,
    # negotiates the handshake, and streams one immutable episode through
    # Execute. Only non-interactive episodes are supported — the worker runs
    # graphs inside the containment host (T4.1) and an interrupting skill is a
    # typed terminal failure (T0.4), never a wait.
    #
    # The runner (injected, T1.4/T2 wiring) executes one episode and yields
    # the wire event vocabulary. Until the runner is wired, Execute refuses
    # with Unimplemented.
    class EpisodeWorker < Agenticstream::Runtime::V1::EpisodeWorker::Service
      PROTOCOL_VERSION = "1.0"
      CONTRACT_VERSION = "1.0"
      WORKER_NAME = "tamoz"
      MAX_REQUEST_BYTES = 4 * 1024 * 1024
      MAX_EVENT_BYTES = 1 * 1024 * 1024
      SUPPORTED_KINDS = [
        Agenticstream::Runtime::V1::EpisodeKind::EPISODE_KIND_DIAGNOSE,
        Agenticstream::Runtime::V1::EpisodeKind::EPISODE_KIND_RECONSIDER
      ].freeze

      def initialize(worker_version:, runner: nil, lane_config: nil)
        @worker_version = worker_version
        @runner = runner
        @lane_config = lane_config
      end

      attr_reader :lane_config

      # The runtime's WorkerExecutor calls Handshake with the worker's declared
      # protocol/contract versions and identity; the worker refuses a contract
      # major mismatch and echoes the negotiated identity back.
      def handshake(request, _call)
        validate_contract!(request)
        Agenticstream::Runtime::V1::HandshakeResponse.new(
          protocol_version: PROTOCOL_VERSION,
          contract_version: CONTRACT_VERSION,
          worker_name: request.worker_id.empty? ? WORKER_NAME : request.worker_id,
          worker_version: @worker_version,
          supported_features: [].freeze,
          max_request_bytes: MAX_REQUEST_BYTES,
          max_event_bytes: MAX_EVENT_BYTES
        )
      end

      # Server-streaming: the worker yields the wire event vocabulary for one
      # episode (started → … → terminal). The runner owns the event stream.
      def execute(request, call)
        raise GRPC::Unimplemented, "episode execution is not wired" unless @runner

        @runner.run(request, call)
      end

      private

      def validate_contract!(request)
        unless request.protocol_version == PROTOCOL_VERSION
          raise GRPC::FailedPrecondition,
                "unsupported protocol version #{request.protocol_version.inspect}"
        end
        unless request.contract_version == CONTRACT_VERSION
          raise GRPC::FailedPrecondition,
                "unsupported contract version #{request.contract_version.inspect}"
        end
        unless request.non_interactive
          raise GRPC::FailedPrecondition,
                "the tamoz worker only serves non-interactive episodes"
        end

        true
      end
    end
  end
end
