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
      WATCH_CONFIDENCE_FLOOR_DEFAULT = 0.5

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
      def kind = KIND_NAMES[@wire.kind]
      def lane = LANE_NAMES.fetch(@wire.lane)
      def risk_ceiling = RISK_NAMES.fetch(@wire.risk_ceiling)
      def capability_token = @wire.capability_token
      def snapshot_sha256 = Tamoz::Core.normalize_digest(@wire.snapshot_sha256)
      def decision_schema_sha256 = Tamoz::Core.normalize_digest(@wire.decision_schema_sha256)
      def tool_catalog_sha256 = Tamoz::Core.normalize_digest(@wire.tool_catalog_sha256)
      def spec_sha256 = Tamoz::Core.normalize_digest(@wire.spec_sha256)
      def prompt_sha256 = Tamoz::Core.normalize_digest(@wire.prompt_sha256)
      def objective_sha256 = Tamoz::Core.normalize_digest(@wire.objective_sha256)
      def diagnosis_catalog_sha256 = Tamoz::Core.normalize_digest(@wire.diagnosis_catalog_sha256)
      def intent_catalog_sha256 = Tamoz::Core.normalize_digest(@wire.intent_catalog_sha256)

      # P6: the wire's Reconsideration, parsed into the durable payload form
      # (nil for DIAGNOSE; a typed refusal for a RECONSIDER without the prior
      # decision).
      def parsed_reconsideration
        return nil unless KIND_NAMES.key?(@wire.kind)
        return nil if kind != :reconsider

        Reconsideration.parse(@wire.reconsideration).to_h
      end

      # P2: the wire budget envelope as a codec-safe hash the graph's
      # ReceiptBudgetController consumes (nil fields = unbounded).
      def budget_hash
        budget = @wire.budget
        return nil if budget.nil?

        {
          "max_model_calls" => budget.max_model_calls.to_i.positive? ? budget.max_model_calls.to_i : nil,
          "max_input_tokens" => budget.max_input_tokens.to_i.positive? ? budget.max_input_tokens.to_i : nil,
          "max_output_tokens" => budget.max_output_tokens.to_i.positive? ? budget.max_output_tokens.to_i : nil,
          "max_tool_calls" => budget.max_tool_calls.to_i.positive? ? budget.max_tool_calls.to_i : nil,
          "max_tool_result_bytes" => budget.max_tool_result_bytes.to_i.positive? ? budget.max_tool_result_bytes.to_i : nil,
          "max_total_tool_result_bytes" => budget.max_total_tool_result_bytes.to_i.positive? ? budget.max_total_tool_result_bytes.to_i : nil,
          "max_provider_retries" => budget.max_provider_retries.to_i.positive? ? budget.max_provider_retries.to_i : nil,
          "max_cost_microunits" => budget.max_cost_microunits.to_i.positive? ? budget.max_cost_microunits.to_i : nil
        }
      end
      def traceparent = blank_to_nil(@wire.traceparent)
      def tracestate = blank_to_nil(@wire.tracestate)

      def watch_confidence_floor
        floor = if @wire.has_watch_confidence_floor?
          @wire.watch_confidence_floor
        else
          WATCH_CONFIDENCE_FLOOR_DEFAULT
        end
        unless floor.is_a?(Numeric) && floor.finite? && floor >= 0
          raise EpisodeRequestInvalidError,
                "watch_confidence_floor must be finite and non-negative"
        end

        floor
      end

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
            "tracestate" => tracestate,
            "watch_confidence_floor" => watch_confidence_floor
          }.freeze,
          # P1/§3.1: the model-authority and frame inputs the fixed graph needs.
          # The graph's build_frame/reason nodes verify and consume these; they
          # are control-plane config, never model output.
          "wire" => {
            "model_policy" => @wire.model_policy.to_s,
            "executor_name" => @wire.executor_name.to_s,
            "dispatch_policy" => @wire.dispatch_policy.to_s,
            "prompt" => @wire.prompt.to_s,
            "prompt_version" => @wire.prompt_version.to_s,
            "prompt_sha256" => prompt_sha256.to_s,
            "diagnosis_catalog_json" => @wire.diagnosis_catalog_json.to_s,
            "diagnosis_catalog_sha256" => diagnosis_catalog_sha256.to_s,
            "intent_catalog_json" => @wire.intent_catalog_json.to_s,
            "intent_catalog_sha256" => intent_catalog_sha256.to_s,
            "skill_refs_json" => @wire.skill_refs_json.to_s,
            "reconsideration" => parsed_reconsideration,
            "objective" => @wire.objective.to_s,
            "objective_sha256" => objective_sha256.to_s,
            "budget" => budget_hash,
            "tool_catalog_json" => @wire.tool_catalog_json.to_s
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
        watch_confidence_floor
        unless @wire.allowed_intent_types.to_a.length <= 16
          raise EpisodeRequestInvalidError,
                "allowed_intent_types must not exceed 16 entries"
        end
        # P4/§B9-B10: the intent catalog is REQUIRED for a diagnose episode —
        # missing (or empty, or forged, checked again at frame build) fails
        # closed BEFORE any model call. The model proposes; the catalog
        # declares the authority.
        if KIND_NAMES[@wire.kind] == :diagnose &&
           (@wire.intent_catalog_json.to_s.empty? || intent_catalog_sha256.to_s.empty?)
          raise EpisodeRequestInvalidError,
                "a diagnose episode requires the intent catalog"
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
        # P6: RECONSIDER is a graph route (intake → judge → compensate). The
        # intent catalog is required for BOTH kinds — the compensate node
        # reads the compensation mapping from it.
        if KIND_NAMES[@wire.kind] == :reconsider &&
           (@wire.intent_catalog_json.to_s.empty? || intent_catalog_sha256.to_s.empty?)
          raise EpisodeRequestInvalidError,
                "a reconsider episode requires the intent catalog"
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
      # Audit F3: the B8-stated proof "provider: test anywhere in a stream
      # artifact invalidates the run" — literal markers no real provider path
      # ever emits. Real fixture receipts carry provider "ollama" + model
      # "local-model" (fixture discrimination is structural, via test wiring);
      # a forged marker is rejected at emit even with matching digests.
      FORGED_PROVIDER_MARKERS = %w[test fixture local-model-fixture].freeze
      def initialize(durable_runner:, worker:, verification_store: nil, artifact_store: nil,
                     configured_tenant: nil, episode_tools: nil)
        @durable_runner = durable_runner
        @worker = worker
        @verification_store = verification_store
        @artifact_store = artifact_store
        @configured_tenant = configured_tenant && String(configured_tenant).dup.freeze
        # P2: an injected capability host (test composition) overrides the
        # runner's per-request host; production keeps the wire-derived host.
        @episode_tools = episode_tools
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
            stream = EpisodeStream.new(
              envelope, worker_name: @worker&.worker_name, worker_version: @worker&.worker_version
            )
            adapter = EpisodeStreamAdapter.new(stream)
            stream.started
            context = Tamoz::Context.new(
              run_id: envelope.request_id,
              execution_id: "episode.#{envelope.episode_id}.#{envelope.attempt_id}.#{envelope.fence}",
              request_id: envelope.request_id,
              interrupt_mode: :non_interactive,
              emitter: adapter,
              deadline: monotonic_deadline(wire_request.deadline),
              metadata: trace_metadata(envelope),
              episode_tools: @episode_tools || build_capability_host(wire_request, snapshot)
            )
            watcher = watch_cancellation(call, context)
            payload = envelope.payload.merge("snapshot" => snapshot)
            # P5: the recall node owns situation memory — the runner no longer
            # seeds the memory channels (they are written once by the graph).
            result = @durable_runner.deliver(
              payload,
              thread: envelope.thread_id,
              request_id: envelope.request_id,
              operation: :turn,
              delivery: :queue,
              namespace: envelope.namespace,
              context:
            )
            status = adapter.terminal_status(result, adapter.last_diagnostic_code)
            terminal_state = nil
            manifest = nil
            if result.checkpoint_id
              # The request's OWN last checkpoint — for a PRODUCED run this is
              # the decide node's state; for a run that failed after the model
              # call it is the last appended step, so the call's receipts are
              # still witnessed (B4: model events come from receipts, and a
              # completed call is never silently dropped).
              checkpoint = @durable_runner.compiled.checkpointer.find(
                thread_id: envelope.thread_id,
                namespace: envelope.namespace,
                checkpoint_id: result.checkpoint_id
              )
              terminal_state = checkpoint.state.to_h
              # P3 (every-attempt bundles): the manifest + retention are built
              # BEFORE any model event or decision crosses the wire — a
              # retention failure must not tear a stream that already
              # published evidence. The crash guarantee is the journal + the
              # checkpoint: retention runs post-run but pre-emission, and a
              # completed journal receipt survives a crash between the call
              # and the runner's terminal branch.
              manifest = build_artifact_manifest(envelope, terminal_state)
              retain_manifest_artifacts(envelope, terminal_state) if @artifact_store
              # The receipts are verified against the JOURNAL before crossing
              # the wire — node-authored state alone is never trusted (B4).
              emit_model_events(adapter, terminal_state, envelope)
            end
            if status == :TERMINAL_STATUS_PRODUCED
              # P1: the terminal graph state IS the decision; the runner only
              # translates it to the wire (B2).
              translate_decision(stream, envelope, terminal_state)
            end
            manifest ||= build_artifact_manifest(envelope, terminal_state)
            stream.terminal(
              status, reason_code: reason_code_for(result),
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
            stream.diagnostic(code:, message: error.message)
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

      # P1: the typed reason on a FAILED terminal — the durable request's
      # terminal error carries the graph failure category; a produced run has
      # none.
      def reason_code_for(result)
        return nil if result.nil? || result.status != :failed

        terminal_error = result.respond_to?(:terminal_error) ? result.terminal_error : nil
        return nil unless terminal_error.is_a?(Hash)

        terminal_error.fetch("category", terminal_error.fetch("graph_status", nil))
      end

      # P1: TRANSLATES the terminal graph state to the wire decision event.
      # The decide node built the decision (B2); this only serializes it. The
      # checkpoint is the request's OWN terminal checkpoint (never the
      # thread's `latest`, which a concurrent fence+1 redispatch could have
      # moved past).
      def translate_decision(stream, envelope, terminal_state)
        decision = terminal_state[:decision]
        digest = terminal_state[:decision_digest]
        if decision.nil? || digest.to_s.empty?
          raise EpisodeRequestInvalidError,
                "produced episode has no terminal decision state"
        end

        stream.decision(
          decision_json: JSON.generate(decision),
          decision_sha256: digest
        )
        [decision, digest]
      end

      # P1/B4: the RUNNER turns receipts into wire model events, AFTER
      # verifying each projection against its durable journal record (fetch by
      # effect_key; the head must be :succeeded and the request digest must
      # match). Node-authored state alone is never trusted, so "a model event
      # without a completed receipt never reaches the wire" holds
      # categorically. Emitted on fresh AND replayed runs from the same stored
      # projections, so replay is ordinal- and digest-identical.
      def emit_model_events(adapter, terminal_state, envelope)
        receipts = Array(terminal_state[:model_receipts])
        return if receipts.empty?

        checkpointer = @durable_runner.compiled.checkpointer
        checkpointer.open_writer(
          thread_id: envelope.thread_id, namespace: envelope.namespace,
          owner_id: "tamoz.episode.wire", ttl: checkpointer.writer_ttl
        ) do |writer|
          receipts.each do |receipt|
            record = writer.effects.fetch(receipt.fetch("effect_key"))
            # The effect key IS the logical call key (request digest bound).
            # Verification: the record exists, the head is :succeeded, and the
            # stored attempt's response digest AND transport request digest
            # match the projection — a forged projection cannot reproduce
            # either journaled value.
            stored_response = journal_response_digest(record)
            stored_request = journal_request_digest(record)
            if record.nil? || record.status != :succeeded ||
               stored_response != receipt.fetch("response_digest") ||
               stored_request != receipt.fetch("request_digest")
              raise StreamError,
                    "wire_refused_model_event/receipt_not_journal_verified"
            end
            # Audit F3 (B8's stated proof, literal): a receipt carrying a
            # FORGED provider marker invalidates the stream artifact even with
            # matching digests — the design's "provider: test anywhere in a
            # stream artifact invalidates the run" is enforced here, before
            # the event reaches the wire. Real fixture receipts carry
            # provider "ollama" + model "local-model" (structural separation
            # is the fixture discrimination); this guard rejects only markers
            # no real path ever produces. A MISSING provider is equally a
            # refusal — a genuine journaled call always carries one.
            if FORGED_PROVIDER_MARKERS.include?(receipt.fetch("provider", ""))
              raise StreamError,
                    "wire_refused_model_event/forged_provider_marker"
            end
            if receipt.fetch("provider", "").to_s.empty?
              raise StreamError,
                    "wire_refused_model_event/missing_provider"
            end

            adapter.emit_stream_part(
              Tamoz::StreamPart.new(
                type: :model_started,
                namespace: [],
                run_id: receipt.fetch("episode_id", ""),
                task_id: "reason",
                sequence: 0,
                data: {
                  "ordinal" => receipt.fetch("ordinal"),
                  "provider" => receipt.fetch("provider"),
                  "model_id" => receipt.fetch("model"),
                  "request_sha256" => receipt.fetch("request_digest")
                },
                emitted_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
              )
            )
            adapter.emit_stream_part(
              Tamoz::StreamPart.new(
                type: :model_completed,
                namespace: [],
                run_id: receipt.fetch("episode_id", ""),
                task_id: "reason",
                sequence: 0,
                data: {
                  "ordinal" => receipt.fetch("ordinal"),
                  "response_sha256" => receipt.fetch("response_digest"),
                  "usage" => receipt["usage"]
                },
                emitted_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
              )
            )
          end
        end
      end

      # The response digest stored on the journaled attempt — the codec
      # projection's response_digest. Only a real completed attempt carries
      # one; a forged projection cannot reproduce it.
      def journal_response_digest(record)
        return nil unless record&.respond_to?(:attempts)

        record.attempts.each do |attempt|
          next unless attempt.status == :succeeded

          result = attempt.respond_to?(:result) ? attempt.result : nil
          return result["response_digest"] if result.is_a?(Hash) && result["response_digest"]
        end
        nil
      end

      # The transport request digest stored on the journaled attempt — the
      # same value the receipt's request_digest carries (P3: the projection is
      # now request-digest-bound, so the emission check covers both sides of
      # the binding).
      def journal_request_digest(record)
        return nil unless record&.respond_to?(:attempts)

        record.attempts.each do |attempt|
          next unless attempt.status == :succeeded

          result = attempt.respond_to?(:result) ? attempt.result : nil
          return result["request_digest"] if result.is_a?(Hash) && result["request_digest"]
        end
        nil
      end

      # T2.3/P3: the per-episode artifact manifest on EVERY terminal — the
      # digests an offline replay needs (PROTOCOL §2). The digests are the
      # STREAM's own (the sha256 values the wire carried), never locally
      # re-derived; the contract version, the memory records the episode
      # grounded on (P5: written by the recall node into the terminal state),
      # the resolved skill-set digest (P5: derived from the wire-carried skill
      # refs + compile-time constants, so live and replay agree), and the run
      # identity complete the manifest.
      def build_artifact_manifest(envelope, terminal_state = nil)
        terminal_state ||= {}
        terminal_digests = Array(terminal_state.fetch(:memory_record_digests, []))
        terminal_memory = Array(terminal_state.fetch(:situation_memory, []))
        skill_set_digest = terminal_state[:skill_set_digest]
        if terminal_state.key?(:memory_record_digests) || terminal_state.key?(:situation_memory)
          unless terminal_memory.map { |projection| projection.fetch("digest") } == terminal_digests
            raise EpisodeRequestInvalidError,
                  "terminal memory digests do not match the recalled projections"
          end
        end

        Agenticstream::Runtime::V1::ArtifactManifest.new(
          prompt_sha256: digest_bytes_or_nil(envelope.prompt_sha256),
          skill_set_sha256: digest_bytes_or_nil(skill_set_digest),
          tool_catalog_sha256: digest_bytes_or_nil(envelope.tool_catalog_sha256),
          model_policy: blank_to_nil(envelope.wire.model_policy),
          contract_version: EpisodeWorker::CONTRACT_VERSION,
          memory_record_sha256: terminal_digests.map { |digest| Tamoz::Core.digest_bytes(digest) }
        )
      end

      # T2.3/P3: retains the documents the manifest names, keyed on the
      # VERIFIED raw digest (sha256 of the exact bytes — the durable store's
      # rehash-on-admission rule), plus the terminal's response content
      # (every-attempt bundles) — so an offline replay resolves every artifact
      # by verified digest. The manifest's digests stay the wire identity; the
      # store's keys are the byte-verified digests. Every wire digest is
      # verified against the bytes it claims to cover BEFORE retention — a
      # lying digest fails closed here, before any model event crosses the
      # wire (prompt and diagnosis-catalog digests are already verified at
      # frame build; tool_catalog/decision_schema are plain byte digests and
      # objective is a domain digest).
      def retain_manifest_artifacts(envelope, terminal_state = nil)
        documents = {
          "tool_catalog" => [envelope.tool_catalog_sha256, envelope.wire.tool_catalog_json],
          "decision_schema" => [envelope.decision_schema_sha256, envelope.wire.decision_schema_json],
          "objective" => [envelope.objective_sha256, envelope.wire.objective],
          "diagnosis_catalog" => [envelope.diagnosis_catalog_sha256, envelope.wire.diagnosis_catalog_json],
          "prompt" => [envelope.prompt_sha256, envelope.wire.prompt]
        }
        documents.each do |name, (wire_digest, bytes)|
          next if bytes.to_s.empty?

          verify_manifest_digest!(name, wire_digest, bytes.to_s)
          @artifact_store.retain(
            digest: "sha256:#{Digest::SHA256.hexdigest(bytes.to_s)}",
            bytes: bytes.to_s,
            media_type: "text/plain"
          )
        end

        # P3 (every-attempt bundles): the terminal's response content is
        # retained under its OWN content digest — an offline replay resolves
        # it by verified digest (the response envelope digest is the gateway's
        # witness; the content digest is the store's).
        Array(terminal_state && terminal_state[:raw_response]).each do |raw|
          next if raw.nil? || raw.empty?

          digest = "sha256:#{Digest::SHA256.hexdigest(raw)}"
          @artifact_store.retain(digest:, bytes: raw, media_type: "text/plain")
        end
      end

      # The wire digest must bind the exact bytes the store will hold: plain
      # sha256 for the byte documents, the objective's own domain digest for
      # the objective text. Verified here so the manifest's identity always
      # resolves in the verified store.
      def verify_manifest_digest!(name, wire_digest, bytes)
        expected = case name
                   when "tool_catalog", "decision_schema"
                     "sha256:#{Digest::SHA256.hexdigest(bytes)}"
                   when "objective"
                     Tamoz::Core.digest(
                       "situation-runtime/objective/v1\n", {"text" => bytes}
                     )
                   else
                     return
                   end
        return if expected == Tamoz::Core.normalize_digest(wire_digest.to_s)

        raise EpisodeRequestInvalidError,
              "manifest_digest_mismatch/#{name}: wire digest does not bind the retained bytes"
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
