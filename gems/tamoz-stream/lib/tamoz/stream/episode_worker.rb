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
    # The worker OWNS the wire contract on both RPCs (mirroring the Go
    # server.go boundary): the handshake refuses unsupported features, and
    # execute validates the request and the event stream itself — a runner
    # bug (missing started, sequence gap, missing terminal, oversized event)
    # never reaches the wire.
    class EpisodeWorker < Agenticstream::Runtime::V1::EpisodeWorker::Service
      PROTOCOL_VERSION = "1.0"
      CONTRACT_VERSION = "1.0"
      WORKER_NAME = "tamoz"
      MAX_REQUEST_BYTES = 4 * 1024 * 1024
      MAX_EVENT_BYTES = 1 * 1024 * 1024
      # Advertised features the worker can back. Evidence tools (T3) will add
      # their feature here when the client is wired; until then a runtime that
      # requires one is refused at the handshake, exactly like the Go worker.
      SUPPORTED_FEATURES = [].freeze
      SUPPORTED_KINDS = %i[EPISODE_KIND_DIAGNOSE EPISODE_KIND_RECONSIDER].freeze

      # P8 (no hidden fallback): the worker declares its provider mode at
      # construction. `fixture` (demos and tests) is refused for a tamoz-mode
      # request — a production route never gets a canned answer.
      PROVIDER_MODES = %i[real fixture].freeze

      def initialize(worker_version:, runner: nil, lane_config: nil, provider_mode: :real)
        @worker_version = worker_version
        @runner = runner
        @lane_config = lane_config
        @provider_mode = provider_mode
        unless PROVIDER_MODES.include?(@provider_mode)
          raise ArgumentError, "unknown provider mode #{@provider_mode.inspect}"
        end
      end

      attr_reader :lane_config, :provider_mode

      def bind_runner(runner)
        @runner = runner
        self
      end

      def worker_name = WORKER_NAME

      def worker_version = @worker_version

      # The runtime's WorkerExecutor calls Handshake with the worker's declared
      # protocol/contract versions and identity; the worker refuses a contract
      # major mismatch or an unsupported required feature, and reports its OWN
      # name (never the peer-claimed identity — the socket path, not the
      # request, is the worker's identity).
      def handshake(request, _call)
        validate_contract!(request)
        if request.worker_id.empty? || request.runtime_instance_id.empty?
          raise GRPC::InvalidArgument,
                "worker_id and runtime_instance_id are required"
        end

        Agenticstream::Runtime::V1::HandshakeResponse.new(
          protocol_version: PROTOCOL_VERSION,
          contract_version: CONTRACT_VERSION,
          worker_name: WORKER_NAME,
          worker_version: @worker_version,
          supported_features: SUPPORTED_FEATURES.dup,
          max_request_bytes: MAX_REQUEST_BYTES,
          max_event_bytes: MAX_EVENT_BYTES
        )
      end

      # Server-streaming: the worker validates the request and the stream
      # contract, then yields the runner's wire events. The runner (injected,
      # T1.4/T2 wiring) executes one episode; until wired, Unimplemented.
      def execute(request, call)
        validate_request!(request)
        raise GRPC::Unimplemented, "episode execution is not wired" unless @runner

        validate_stream(@runner.run(request, call))
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
        request.requested_features.each do |feature|
          next if SUPPORTED_FEATURES.include?(feature)

          raise GRPC::FailedPrecondition,
                "unsupported required feature #{feature.inspect}"
        end

        true
      end

      # T1.3'/T1.2 parity with the Go validateRequest: the RPC that spends
      # model budget is validated at the worker boundary, never only in the
      # runner. (non_interactive is handshake-only — the request itself has no
      # such field.)
      def validate_request!(request)
        unless request.protocol_version == PROTOCOL_VERSION
          raise GRPC::FailedPrecondition,
                "unsupported protocol version #{request.protocol_version.inspect}"
        end
        if request.episode_id.empty? || request.attempt_id.empty?
          raise GRPC::InvalidArgument,
                "episode_id and attempt_id are required"
        end
        unless request.fence.is_a?(Integer) && request.fence >= 1
          raise GRPC::InvalidArgument, "fence must be a positive integer"
        end
        unless SUPPORTED_KINDS.include?(request.kind)
          raise GRPC::FailedPrecondition,
                "unsupported episode kind #{request.kind.inspect}"
        end
        size = request.to_proto.bytesize
        if size > MAX_REQUEST_BYTES
          raise GRPC::ResourceExhausted,
                "episode request exceeds #{MAX_REQUEST_BYTES} bytes"
        end
        # P8 (no hidden fallback): a FIXTURE provider can never serve a
        # tamoz-mode (or active) request — a production route gets a real
        # model answer or a hard failure, never a canned decision.
        refuse_fixture_fallback!(request)

        true
      end

      def refuse_fixture_fallback!(request)
        return unless @provider_mode == :fixture &&
                      (request.executor_name == "tamoz" ||
                       request.dispatch_policy == :DISPATCH_POLICY_ACTIVE)

        raise GRPC::FailedPrecondition,
              "fixture provider cannot serve a tamoz/active request (no hidden fallback)"
      end

      # The worker owns the stream contract (Go streamValidator parity): the
      # runner's events are validated for exact sequence, one terminal, no
      # event after the terminal, and the event-size bound — and the terminal
      # is forced when the runner forgets it.
      def validate_stream(enumerator)
        Enumerator.new do |yielder|
          state = { expected_sequence: 1, terminal_seen: false }
          enumerator.each do |event|
            validate_stream_event(event, state)
            yielder << event
          end
          ensure_terminal(state)
        end
      end

      def validate_stream_event(event, state)
        unless event.sequence == state[:expected_sequence]
          raise GRPC::Internal,
                "episode event sequence mismatch: got #{event.sequence}, expected #{state[:expected_sequence]}"
        end
        state[:expected_sequence] += 1
        if event.to_proto.bytesize > MAX_EVENT_BYTES
          raise GRPC::ResourceExhausted,
                "episode event exceeds #{MAX_EVENT_BYTES} bytes"
        end
        raise GRPC::Internal, "episode emitted an event after its terminal" if state[:terminal_seen]

        state[:terminal_seen] = true if event.terminal != nil
      end

      def ensure_terminal(state)
        return if state[:terminal_seen]

        raise GRPC::Internal, "episode stream ended without a terminal"
      end
    end
  end
end
