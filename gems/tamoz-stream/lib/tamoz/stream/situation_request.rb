# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"
require "tamoz/stream/episode_stream"
require "tamoz/stream/decision_builder"
require "tamoz/stream/capability_host"
require "tamoz/stream/evidence_client"
require "tamoz/stream/reconsideration"
require "tamoz/stream/verification_store"
require "tamoz/stream/artifact_store"
require "tamoz/stream/situation_recall"
# The runner composes episodes for the worker and reports the worker's
# contract version on the artifact manifest — the worker's constant is the
# single source of truth for the protocol version.
require "tamoz/stream/episode_worker"
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
      def snapshot_sha256 = Tamoz::Core.normalize_digest(@wire.snapshot_sha256)
      def decision_schema_sha256 = Tamoz::Core.normalize_digest(@wire.decision_schema_sha256)
      def tool_catalog_sha256 = Tamoz::Core.normalize_digest(@wire.tool_catalog_sha256)
      def spec_sha256 = Tamoz::Core.normalize_digest(@wire.spec_sha256)
      def prompt_sha256 = Tamoz::Core.normalize_digest(@wire.prompt_sha256)
      def objective_sha256 = Tamoz::Core.normalize_digest(@wire.objective_sha256)
      def traceparent = blank_to_nil(@wire.traceparent)
      def tracestate = blank_to_nil(@wire.tracestate)

      TRACEPARENT_PATTERN = /\A(?:00|[0-9a-f]{2})-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/.freeze

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
      # verified snapshot under "snapshot" after ReceivedSnapshot passes. The
      # capability token stays in memory only (on the envelope) — it is never
      # persisted in the durable payload or the checkpoint state.
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
            "evidence_tools_endpoint" => @wire.evidence_tools_endpoint,
            "allowed_intent_types" => @wire.allowed_intent_types.to_a.freeze,
            "supersession_key" => @wire.supersession_key,
            "cancellation_key" => @wire.cancellation_key,
            "snapshot_json" => @wire.snapshot_json,
            "snapshot_sha256" => snapshot_sha256,
            "traceparent" => traceparent,
            "tracestate" => tracestate
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
        # guarantee depends on an unambiguous join. They are also bounded and
        # control-char-free — an oversized identity would otherwise amplify
        # into unbounded wire events.
        %w[episode_id attempt_id tenant_id].each do |field|
          value = @wire.public_send(field)
          if value.empty?
            raise EpisodeRequestInvalidError, "#{field} is required"
          end
          if field != "tenant_id" && value.include?(".")
            raise EpisodeRequestInvalidError,
                  "#{field} must not contain '.'"
          end
          if value.bytesize > 200 || value.match?(/[\x00-\x1F\x7F]/)
            raise EpisodeRequestInvalidError,
                  "#{field} must be at most 200 bytes with no control characters"
          end
        end
        unless @wire.fence.is_a?(Integer) && @wire.fence >= 1
          raise EpisodeRequestInvalidError,
                "episode fence must be a positive integer"
        end
        unless @wire.allowed_intent_types.to_a.length <= 16
          raise EpisodeRequestInvalidError,
                "allowed_intent_types must not exceed 16 entries"
        end
        validate_budget!
        if traceparent && !traceparent.match?(TRACEPARENT_PATTERN)
          raise EpisodeRequestInvalidError, "traceparent is malformed"
        end
        if tracestate && tracestate.bytesize > 512
          raise EpisodeRequestInvalidError, "tracestate exceeds 512 bytes"
        end
        unless KIND_NAMES.key?(@wire.kind)
          raise EpisodeRequestInvalidError,
                "unsupported episode kind #{@wire.kind.inspect}"
        end
        # T6: a RECONSIDER episode judges a prior action — without the prior
        # Decision/commands/outcomes/correction it cannot judge. Fail closed.
        if KIND_NAMES.fetch(@wire.kind) == :reconsider && @wire.reconsideration.nil?
          raise EpisodeRequestInvalidError,
                "a RECONSIDER episode requires the reconsideration payload"
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

      # F-2 (security review): the budget is the worker's only resource
      # control — a hostile budget must not be able to disable it. Values are
      # clamped to worker maxima, fail-closed.
      MAX_WALL_TIME_SECONDS = 600
      MAX_MODEL_CALLS = 50

      def validate_budget!
        budget = @wire.budget
        return if budget.nil?

        if budget.wall_time&.seconds && budget.wall_time.seconds > MAX_WALL_TIME_SECONDS
          raise EpisodeRequestInvalidError,
                "wall_time exceeds the worker maximum of #{MAX_WALL_TIME_SECONDS}s"
        end
        if budget.max_model_calls.to_i > MAX_MODEL_CALLS
          raise EpisodeRequestInvalidError,
                "max_model_calls exceeds the worker maximum of #{MAX_MODEL_CALLS}"
        end

        true
      end

      def blank_to_nil(value)
        value.to_s.empty? ? nil : value.to_s
      end
    end

    # T1.4: runs one episode as a durable request through the durable runner —
    # enqueued under the fenced id, executed inside the non-interactive
    # containment context, so a crash mid-episode resumes from a checkpoint
    # and a redelivery is idempotent. The wire event stream (T2.1) turns the
    # run into EpisodeEvent payloads; the runner here returns the durable
    # RequestRecord.
    class EpisodeRunner
      def initialize(durable_runner:, worker:, verification_store: nil, artifact_store: nil,
                     situation_recaller: nil, configured_tenant: nil, recall_caller: nil)
        @durable_runner = durable_runner
        @worker = worker
        @verification_store = verification_store
        @artifact_store = artifact_store
        @situation_recaller = situation_recaller
        @configured_tenant = configured_tenant && String(configured_tenant).dup.freeze
        @recall_caller = recall_caller
        validate_graph_recall_contract!
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
              wire_request.snapshot_json, envelope.snapshot_sha256
            )
            # F-5: the durable row and the decision carry the SNAPSHOT's
            # tenant/situation identity — a mismatched wire header is a
            # cross-tenant identity confusion, refused here.
            if wire_request.tenant_id != snapshot.fetch("tenant_id") ||
               wire_request.situation_id != snapshot.fetch("situation_id") ||
               wire_request.situation_version != snapshot.fetch("situation_version")
              raise EpisodeRequestInvalidError,
                    "request identity does not match the verified snapshot"
            end
            if @configured_tenant &&
               (wire_request.tenant_id != @configured_tenant ||
                snapshot.fetch("tenant_id") != @configured_tenant)
              raise EpisodeRequestInvalidError, "request tenant does not match configured tenant"
            end
            recall = recall_for(snapshot, envelope)
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
              emitter: adapter,
              deadline: monotonic_deadline(wire_request.deadline),
              metadata: trace_metadata(envelope),
              episode_tools: build_capability_host(wire_request, snapshot)
            )
            watcher = watch_cancellation(call, context)
            payload = envelope.payload.merge(
              "snapshot" => snapshot,
              "situation_memory" => recall.projections,
              "memory_record_digests" => recall.record_digests
            )
            if envelope.kind == :reconsider
              payload = payload.merge(
                "reconsideration" => Reconsideration.parse(
                  wire_request.reconsideration
                ).to_h
              )
            end
            result = @durable_runner.deliver(
              payload,
              thread: envelope.thread_id,
              request_id: envelope.request_id,
              operation: :turn,
              delivery: :queue,
              namespace: envelope.namespace,
              context:
            )
            status, reason = adapter.terminal_status(result)
            if status == :TERMINAL_STATUS_PRODUCED
              decision, digest = emit_decision(
                stream, envelope, snapshot, result
              )
              open_verifications(envelope, snapshot, decision, digest)
            end
            # T2.3: the manifest and its retention are for PRODUCED episodes
            # only — a FAILED/BUDGET_EXHAUSTED episode has no accepted
            # Decision to reproduce, and its inputs are not retained.
            manifest = nil
            if status == :TERMINAL_STATUS_PRODUCED
              manifest = build_artifact_manifest(envelope, result, recall)
              retain_manifest_artifacts(envelope) if @artifact_store
            end
            stream.terminal(
              status, reason_code: reason, usage: adapter.wire_usage,
              artifact_manifest: manifest
            )
          rescue Tamoz::Stream::StreamError => error
            # A refused episode still terminates the wire stream with a typed
            # FAILED terminal — never a bare RPC error, and never a model call.
            stream ||= EpisodeStream.new(identity_for(wire_request))
            stream.diagnostic(code: error.class::CATEGORY, message: error.message)
            stream.terminal(:TERMINAL_STATUS_FAILED, reason_code: error.class::CATEGORY)
          rescue StandardError => error
            # ANY other failure terminates the stream typed — the "exactly one
            # terminal" contract holds even when the builder misbehaves. A
            # Tamoz::Error carries its typed category (the non-interactive
            # interrupt is interrupt_in_non_interactive_episode, never a bare
            # internal_error); everything else stays class-named.
            code = if error.class.const_defined?(:CATEGORY)
                     error.class::CATEGORY
                   else
                     "internal_error"
                   end
            stream ||= EpisodeStream.new(identity_for(wire_request))
            stream.diagnostic(code:, message: error.class.name)
            stream.terminal(:TERMINAL_STATUS_FAILED, reason_code: code)
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
      # concurrent fence+1 redispatch could have moved past). Returns the
      # [decision, digest] pair so T5.2 can open verification rows per intent.
      def emit_decision(stream, envelope, snapshot, result)
        return [nil, nil] unless result.checkpoint_id

        checkpoint = @durable_runner.compiled.checkpointer.find(
          thread_id: envelope.thread_id,
          namespace: envelope.namespace,
          checkpoint_id: result.checkpoint_id
        )
        outcome = checkpoint.state.to_h
        decision, digest = DecisionBuilder.build(
          envelope:, snapshot:,
          snapshot_digest: envelope.snapshot_sha256,
          outcome: outcome.transform_keys(&:to_sym)
        )
        stream.decision(
          decision_json: JSON.generate(decision),
          decision_sha256: digest
        )
        [decision, digest]
      end

      # T5.2: a produced episode opens an :awaiting verification row per
      # intent. The row carries everything the subscriber needs to admit the
      # Experience when outcome.reconciled arrives (possibly days later), with
      # the situation scopes so the Experience is reachable by the T5.4
      # situation-scoped retrieval path.
      def open_verifications(envelope, snapshot, decision, digest)
        return unless @verification_store && decision

        entity = snapshot.fetch("entity")
        episode_content = {
          session_id: envelope.episode_id,
          episode_id: envelope.episode_id,
          attempt_id: envelope.attempt_id,
          task: "stream episode #{envelope.episode_id} " \
                "attempt #{envelope.attempt_id}",
          plan_digest: digest,
          completed_at: Time.now.to_i,
          traceparent: envelope.traceparent,
          tracestate: envelope.tracestate,
          scopes: {
            "tenant" => envelope.tenant_id,
            "user" => "stream",
            "project" => "stream",
            "situation_type" => snapshot.fetch("situation_type"),
            "entity_type" => entity.fetch("type"),
            "entity_id" => entity.fetch("id")
          },
          sensitivity: :internal,
          decisions: [String(decision.fetch("primary_hypothesis", ""))],
          corrections: []
        }
        decision.fetch("intents", []).each do |intent|
          # A watch condition (R0) has no command and no outcome to verify —
          # verification rows open only for consequential intents.
          next if intent.fetch("risk_class", "R0").to_s.upcase == "R0"

          @verification_store.open(
            tenant_id: envelope.tenant_id,
            intent_id: intent.fetch("intent_id"),
            episode_id: envelope.episode_id,
            attempt_id: envelope.attempt_id,
            decision_digest: digest,
            episode: episode_content,
            decision_id: intent.fetch("decision_id")
          )
        end
      end

      # T2.3: the per-episode artifact manifest on the terminal — the digests
      # a shadow run needs to compare (PROTOCOL §2). The digests are the
      # STREAM's own (the sha256 values the wire carried), never locally
      # re-derived; the contract version and the memory records the episode
      # grounded on complete the manifest. The checkpoint lookup uses the
      # envelope's own thread/namespace, matching emit_decision.
      def build_artifact_manifest(envelope, result, recall)
        memory_digests = recall.record_digests
        if result&.checkpoint_id
          checkpoint = @durable_runner.compiled.checkpointer.find(
            thread_id: envelope.thread_id,
            namespace: envelope.namespace,
            checkpoint_id: result.checkpoint_id
          )
          terminal_state = checkpoint&.state&.to_h || {}
          terminal_digests = Array(terminal_state.fetch(:memory_record_digests, []))
          if !@situation_recaller && (!terminal_digests.empty? || !Array(terminal_state.fetch(:situation_memory, [])).empty?)
            raise EpisodeRequestInvalidError,
                  "terminal memory requires an authorized situation recaller"
          end
          unless terminal_digests == memory_digests
            raise EpisodeRequestInvalidError,
                  "terminal memory digests do not match the authorized recall"
          end
          terminal_memory = Array(terminal_state.fetch(:situation_memory, []))
          unless terminal_memory == recall.projections
            raise EpisodeRequestInvalidError,
                  "terminal situation memory does not match the authorized recall"
          end
        end
        Agenticstream::Runtime::V1::ArtifactManifest.new(
          prompt_sha256: digest_bytes_or_nil(envelope.prompt_sha256),
          skill_set_sha256: nil,
          tool_catalog_sha256: digest_bytes_or_nil(envelope.tool_catalog_sha256),
          model_policy: blank_to_nil(envelope.wire.model_policy),
          contract_version: EpisodeWorker::CONTRACT_VERSION,
          memory_record_sha256: memory_digests.map { |digest| Tamoz::Core.digest_bytes(digest) }
        )
      end

      # T2.3: retains the documents the manifest names, keyed on the STREAM's
      # digests, so a shadow run can resolve them without re-running Tamoz.
      # Each document is keyed under ITS OWN named digest — the objective
      # under objective_sha256, never under the prompt's digest.
      def retain_manifest_artifacts(envelope)
        {
          envelope.tool_catalog_sha256 => envelope.wire.tool_catalog_json,
          envelope.decision_schema_sha256 => envelope.wire.decision_schema_json,
          envelope.objective_sha256 => envelope.wire.objective
        }.each do |digest, bytes|
          next if digest.to_s.empty? || bytes.to_s.empty?

          @artifact_store.retain(digest:, bytes: bytes.to_s, media_type: "application/json")
        end
      end

      def blank_to_nil(value)
        value.to_s.empty? ? nil : value.to_s
      end

      def digest_bytes_or_nil(value)
        return nil if value.to_s.empty?

        Tamoz::Core.digest_bytes(value)
      end

      # The wire deadline is a wall-clock Timestamp; the Context deadline is on
      # the monotonic clock. The offset converts once at admission.
      def monotonic_deadline(wire_timestamp)
        return nil unless wire_timestamp

        wall = wire_timestamp.seconds + wire_timestamp.nanos.to_f / 1_000_000_000
        wall - (Time.now.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC))
      end

      # T3.2: the episode tool surface. The containment host (T4.1) binds the
      # fixed seven-name allowlist; the evidence channel (when the request
      # carries an endpoint and a token) is the reverse-channel client scoped
      # to the VERIFIED snapshot's identity — otherwise the surface is bound
      # to refusal adapters and evidence refuses. The host is read-only and
      # bounded by construction; the graph reaches it only through
      # context.episode_tools. The host's result cap is the tighter of the
      # hard ceiling and the wire budget's max_tool_result_bytes.
      def build_capability_host(wire_request, snapshot)
        if wire_request.evidence_tools_endpoint.to_s.empty? ||
           wire_request.capability_token.to_s.empty?
          implementations = EpisodeCapabilityHost::PERMITTED.to_h do |name|
            [name, EvidenceUnavailableAdapter.new(tool_name: name)]
          end
        else
          client = EvidenceClient.new(
            endpoint: wire_request.evidence_tools_endpoint,
            capability_token: wire_request.capability_token,
            episode_id: wire_request.episode_id,
            attempt_id: wire_request.attempt_id,
            fence: wire_request.fence,
            tenant_id: snapshot.fetch("tenant_id"),
            situation_id: snapshot.fetch("situation_id"),
            situation_version: snapshot.fetch("situation_version"),
            entity_id: snapshot.fetch("entity").fetch("id"),
            # The wire budget has no row cap — max_rows stays unset (a byte
            # budget must never masquerade as a row count).
            max_rows: nil,
            max_bytes: wire_request.budget&.max_tool_result_bytes,
            time_from: wire_request.evidence_time_range&.from&.seconds,
            time_until: wire_request.evidence_time_range&.until&.seconds,
            traceparent: wire_request.traceparent,
            tracestate: wire_request.tracestate
          )
          implementations = EpisodeCapabilityHost::PERMITTED.to_h do |name|
            [name, EvidenceToolAdapter.new(client, tool_name: name)]
          end
        end
        EpisodeCapabilityHost.new(
          implementations,
          max_result_bytes: host_result_cap(wire_request)
        )
      end

      def host_result_cap(wire_request)
        budget = wire_request.budget
        return EpisodeCapabilityHost::MAX_RESULT_BYTES if budget.nil?

        [EpisodeCapabilityHost::MAX_RESULT_BYTES,
         budget.max_tool_result_bytes.to_i].reject(&:zero?).min
      end

      def validate_graph_recall_contract!
        return unless @situation_recaller

        compiled = @durable_runner.compiled
        channels = compiled.channels
        %i[situation_memory memory_record_digests].each do |channel|
          next if channels.key?(channel)

          raise ArgumentError, "recall-enabled episode graph must declare #{channel}"
        end
        %i[situation_memory memory_record_digests].each do |channel_name|
          channel = channels.fetch(channel_name)
          unless channel.immutable? && channel.reducer.nil? && channel.default(compiled.codec) == []
            raise ArgumentError,
                  "recall channel #{channel_name} must be immutable with a [] default and no reducer"
          end
        end
      end

      def recall_for(snapshot, envelope)
        return SituationRecall::Result.new unless @situation_recaller
        unless @recall_caller
          raise ArgumentError, "recall-enabled EpisodeRunner requires recall_caller"
        end
        unless @recall_caller[:tenant] == envelope.tenant_id ||
               @recall_caller["tenant"] == envelope.tenant_id
          raise EpisodeRequestInvalidError, "recall caller tenant does not match the episode tenant"
        end

        SituationRecall.validate!(@situation_recaller.recall(
          caller: @recall_caller, snapshot:, query: {terms: []}, limit: 64
        ))
      end

      def trace_metadata(envelope)
        {
          "traceparent" => envelope.traceparent,
          "tracestate" => envelope.tracestate
        }.compact.freeze
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
