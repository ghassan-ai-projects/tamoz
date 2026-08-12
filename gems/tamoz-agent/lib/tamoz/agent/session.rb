# frozen_string_literal: true

require "securerandom"

module Tamoz
  module Agent
    SessionOutcome = Data.define(
      :status,
      :request_status,
      :thread_id,
      :execution_id,
      :request_id,
      :approvals,
      :blocked,
      :result,
      :provider_ambiguity,
      :state
    ) do
      def completed? = status == :completed
      def paused? = status == :paused
      def blocked? = status == :blocked
      def failed? = status == :failed
    end

    SessionView = Data.define(
      :thread_id,
      :checkpoint_id,
      :sequence,
      :execution_id,
      :status,
      :phase,
      :accepted_plan,
      :approvals,
      :effect_receipts,
      :blocked,
      :terminal,
      :provider_ambiguity,
      :interrupts,
      :state
    )

    # The durable agent lifecycle: one graph turn over the existing DurableRunner,
    # checkpoint store, request inbox, lease/fence, and effect journal.
    #
    # `Session` is durable-only by construction. Ephemeral and read-only work stays on
    # `Tamoz::Agent::Runtime`; PERSISTENCE_DESIGN §9 forbids using the in-memory adapter
    # to claim crash durability or effect safety, so no ephemeral Session is offered.
    class Session
      GRAPH_NAME = "tamoz.agent.session"
      GRAPH_VERSION = "1"
      CURRENT_GRAPH_VERSION = "2"
      SUPPORTED_GRAPH_VERSIONS = [GRAPH_VERSION, CURRENT_GRAPH_VERSION].freeze
      MODEL_CALL_SAFETIES = %i[idempotent unsafe].freeze
      ROUTINGS = %i[legacy experimental].freeze

      attr_reader :app, :definition, :toolbox

      # P15-W: the sealed P18 capability host this session was constructed
      # with. Exposed read-only so an operator (and the audit) can inspect the
      # exact surface a thread is bound to without reaching into the nodes.
      def capabilities = @nodes.capabilities

      def initialize(
        model:,
        toolbox:,
        checkpointer:,
        max_plan_attempts: 3,
        max_repair_attempts: Runtime::MAX_REPAIR_ATTEMPTS,
        model_call_safety: :idempotent,
        profile: nil,
        mcp: nil,
        profile_roles: nil,
        profile_budgets: nil,
        memory: nil,
        memory_owner: nil,
        routing: :legacy
      )
        raise ArgumentError, "model must respond to generate" unless model.respond_to?(:generate)
        unless max_plan_attempts.is_a?(Integer) && max_plan_attempts.between?(1, 10)
          raise ArgumentError, "max_plan_attempts must be between 1 and 10"
        end
        unless max_repair_attempts.is_a?(Integer) && max_repair_attempts.between?(0, 10)
          raise ArgumentError, "max_repair_attempts must be between 0 and 10"
        end
        unless MODEL_CALL_SAFETIES.include?(model_call_safety)
          raise ArgumentError,
                "model_call_safety must be one of #{MODEL_CALL_SAFETIES.join(", ")}"
        end
        raise ArgumentError, "routing must be one of #{ROUTINGS.join(", ")}" unless ROUTINGS.include?(routing.to_sym)
        unless checkpointer.respond_to?(:durable?) && checkpointer.durable?
          raise ConfigurationError,
                "Tamoz::Agent::Session requires a durable checkpointer; use " \
                "Tamoz::Agent::Runtime for ephemeral work"
        end

        verify_mcp_source!(mcp)
        @toolbox = toolbox
        @mcp = mcp
        # P11: the optional memory surface and its per-session owner. Nil keeps
        # every memory branch inert (pre-P11 sessions resume byte-identically).
        @memory = memory
        @memory_owner = memory_owner
        @default_graph_version = routing.to_sym == :experimental ? CURRENT_GRAPH_VERSION : GRAPH_VERSION
        verify_profile_binding!(profile)
        node_arguments = {
          model:,
          toolbox:,
          max_plan_attempts:,
          max_repair_attempts:,
          model_call_safety:,
          profile:,
          mcp:,
          profile_roles:,
          profile_budgets:,
          memory:,
          memory_owner:,
          transcript_reader: ->(thread_id:, request_id:) { conversation_transcript(thread_id:, request_id:) }
        }
        @nodes_v1 = SessionNodes.new(**node_arguments, graph_version: GRAPH_VERSION)
        @nodes = SessionNodes.new(**node_arguments, graph_version: CURRENT_GRAPH_VERSION)
        @definitions = {
          GRAPH_VERSION => Session.build_definition(
            @nodes_v1,
            version: GRAPH_VERSION
          ),
          CURRENT_GRAPH_VERSION => Session.build_definition(
            @nodes,
            version: CURRENT_GRAPH_VERSION
          )
        }.freeze
        @apps = @definitions.transform_values { |definition| definition.compile(checkpointer:) }.freeze
        @definition = @definitions.fetch(@default_graph_version)
        @app = @apps.fetch(@default_graph_version)
        @runner = @app.durable_runner
        freeze
      end

      # P10 §3 boundary: the agent never depends on tamoz-mcp; the caller-supplied
      # source is duck-typed, and every MCP-specific behaviour is its own method.
      def verify_mcp_source!(mcp)
        return unless mcp

        required = %i[
          mcp_catalogs catalogs names read_only_names name? read_only?
          approval_required? maximum_effect_output_bytes validate effect_intent
          preview execute
        ]
        missing = required.reject { |method| mcp.respond_to?(method) }
        unless missing.empty?
          raise ArgumentError,
                "mcp source must respond to #{missing.join(", ")}"
        end
      end
      private :verify_mcp_source!

      # P8 §5.2: the toolbox must expose exactly the capability surface the
      # profile pins; a mismatch fails here, before any model I/O.
      def verify_profile_binding!(profile)
        return unless profile

        # A profile pins TWO catalogs, because it describes two situations. The
        # interactive catalog is what a human drives; the unattended catalog is
        # what a worker drives, and it differs only by needing approval on more
        # tools — the `unattended` section decides which. Both are pinned
        # explicitly, so neither can be reached by mutating the other, and a
        # session that matches neither is refused.
        expected = profile.policy.fetch("tool_catalog_digest")
        unattended = profile.policy["unattended_catalog_digest"]
        unless toolbox.catalog_digest == expected ||
               (unattended && toolbox.catalog_digest == unattended)
          pinned = [expected, unattended].compact.join(" or ")
          raise Profile::ValidationError,
                "toolbox catalog digest #{toolbox.catalog_digest} does not match " \
                "profile #{profile.profile_id.inspect} policy.tool_catalog_digest #{pinned}"
        end
        unless toolbox.root.to_s == File.expand_path(profile.canonical_root)
          raise Profile::ValidationError,
                "toolbox root #{toolbox.root} does not match profile canonical_root " \
                "#{profile.canonical_root.inspect}"
        end
      end
      private :verify_profile_binding!

      # P9 §7, invariant 41: a resumed session must bind the exact skill tree it was
      # planned against. Any epoch difference stops; there is no degraded read-only
      # continuation, because a changed skill body is changed *instructions* and
      # continuing an accepted plan under different instructions is the failure the
      # invariant names. Legacy and skill-free sessions share the "none" epoch, so
      # pre-P9 sessions resume untouched.
      #
      # This is the public entry point for operations that reuse an existing thread
      # without going through `guard_state!` (the CLI's follow-up and redirect).
      # `resume`, `continue`, and `recover` enforce the same rule through
      # `guard_state!`, so no programmatic caller can bypass it by not calling this.
      def verify_skill_binding!(thread:)
        stored = stored_state(thread)
        enforce_skill_binding!(thread, stored) if stored
        nil
      end

      def verify_graph_binding!(thread:)
        stored = stored_state(thread)
        enforce_graph_binding!(thread, stored) if stored
        nil
      end

      # P10 §5 epoch rules: a resumed session must bind the exact MCP catalog
      # digests it was planned against. A digest mismatch stops with the typed
      # `McpCatalogSnapshotUnavailableError` — no silent schema substitution. The
      # same guard shape as `verify_skill_binding!`: legacy sessions (no
      # `mcp_catalogs` → `{}`) and MCP-free sessions share the empty pin, so a
      # pre-P10 session and a session built without an MCP source resume
      # identically, and every mismatch fails closed.
      def verify_mcp_binding!(thread:)
        stored = stored_state(thread)
        enforce_mcp_binding!(thread, stored) if stored
        nil
      end

      # P17 (correction 5): a resumed session must bind the exact egress
      # declaration it was planned under. A mismatch stops with the typed
      # `EgressBindingUnavailableError` — a changed egress declaration is a
      # changed network policy (invariant 35/36), so there is no degraded
      # read-only continuation. The empty pin `{}` covers both the pre-P17
      # session and the "profile has no egress section" state, so sessions that
      # never declared egress resume identically.
      def verify_egress_binding!(thread:)
        stored = stored_state(thread)
        enforce_egress_binding!(thread, stored) if stored
        nil
      end

      # P11-W / DR-1: a resumed session must bind the exact behavior version it
      # was planned under. A changed behavior version fails closed
      # (`BehaviorSnapshotUnavailableError`): the Wisdom (or heuristic) snapshot
      # is changed instructions, and resuming an accepted plan under changed
      # instructions is the silent behavior change invariant 28 forbids. The
      # pinned snapshot is replayed from the Store by digest; resume verifies
      # the served injection region against the pinned snapshot (region
      # comparison, DR-1 §4 C5). Existing threads are pinned: resume/continue/
      # redirect are boundary: false and never rewrite the session record.
      def verify_behavior_binding!(thread:)
        return unless @memory

        stored = stored_state(thread)
        enforce_behavior_binding!(thread, stored) if stored
        nil
      end

      # A thread with no checkpoint has nothing to protect: intake will write the
      # current epoch. Every other failure — corruption, an unsupported record
      # version — propagates, because a guard that swallows an unreadable record
      # fails *open*, which is the opposite of what invariant 41 asks for.
      def stored_state(thread)
        app = app_for_thread(thread)
        snapshot = app.checkpointer.latest(thread_id: thread, namespace: [])
        return nil unless snapshot

        SessionRecords.load_state!(app.snapshot(snapshot).state)
      end
      private :stored_state

      def enforce_graph_binding!(thread, state)
        record = state[:session]
        return unless record

        stored = record.fetch("graph_version")
        return if SUPPORTED_GRAPH_VERSIONS.include?(stored)

        raise Tamoz::CheckpointVersionError,
              "session #{thread} uses graph version #{stored.inspect}; this runtime supports " \
              "#{SUPPORTED_GRAPH_VERSIONS.join(", ")}. Start a new session or use a compatible runtime."
      end
      private :enforce_graph_binding!

      def enforce_skill_binding!(thread, state)
        record = state[:session]
        return unless record

        stored = record.fetch("skill_epoch", Tamoz::Core::LEGACY_SKILL_EPOCH)
        current = toolbox.skill_epoch
        return if stored == current

        raise SkillSnapshotUnavailableError,
              "session #{thread} was planned against skill epoch #{stored}; the current " \
              "catalog is #{current}. Restore the exact skill trees or start a new session."
      end
      private :enforce_skill_binding!

      def enforce_mcp_binding!(thread, state)
        record = state[:session]
        return unless record

        stored = record.fetch("mcp_catalogs", {})
        current = @mcp ? @mcp.mcp_catalogs : {}
        return if stored == current

        raise McpCatalogSnapshotUnavailableError,
              "session #{thread} was planned against MCP catalog digests #{stored.inspect}; " \
              "the current source exposes #{current.inspect}. Restore the exact catalog " \
              "snapshots or start a new session."
      end
      private :enforce_mcp_binding!

      def enforce_egress_binding!(thread, state)
        record = state[:session]
        return unless record

        stored = record.fetch("egress_pin", {})
        current = current_egress_pin
        return if stored == current

        raise EgressBindingUnavailableError,
              "session #{thread} was pinned to egress declaration #{stored.inspect}; the " \
              "current profile declares #{current.inspect}. Restore the exact profile " \
              "egress section or start a new session."
      end
      private :enforce_egress_binding!

      # DR-1 §7 resume binding: the pinned snapshot is REPLAYED on resume (the
      # old version is kept — resume/continue/redirect never rewrite the
      # session record and never silently upgrade). The resume "fails closed"
      # against a changed behavior version by serving exactly the pinned
      # snapshot; if that snapshot can no longer be rebuilt from the Store, the
      # resume stops typed (`BehaviorSnapshotUnavailableError`) instead of
      # silently running under a different behavior.
      def enforce_behavior_binding!(thread, state)
        record = state[:session]
        return unless record

        digest = record["behavior_snapshot_digest"]
        return unless digest

        snapshot = @memory.transitions.snapshot_for(digest)
        return if snapshot

        raise Tamoz::Agent::Memory::BehaviorSnapshotUnavailableError,
              "session #{thread} pinned behavior snapshot #{digest} is unavailable; " \
              "start a new thread to adopt the promoted behavior"
      end
      private :enforce_behavior_binding!

      # The egress declaration the session was CONSTRUCTED with (the profile's
      # validated `egress:` section, canonically normalized). `{}` means "no
      # egress declaration" — the state a profile-less session and a session
      # whose profile has no egress section share.
      def current_egress_pin
        return {} unless @nodes.profile && @nodes.profile.egress

        Tamoz::Agent::Deliberation.canonical(@nodes.profile.egress)
      end
      private :current_egress_pin

      # Reads the conversation transcript a channel turn carries in its
      # request payload, through the compiled app's BOUND checkpointer (what
      # arrives at the constructor is the unbound adapter).
      def conversation_transcript(thread_id:, request_id:)
        SessionPlanningContext.transcript_from(@app.checkpointer, thread_id:, request_id:)
      end
      private :conversation_transcript

      def self.build_definition(nodes, version: GRAPH_VERSION)
        routed = String(version) == CURRENT_GRAPH_VERSION
        Tamoz.graph(name: GRAPH_NAME, version: String(version)) do
          state :task, default: ""
          state :phase, default: ""
          state :next_node, default: "intake"
          state :terminal_reason, default: "no_check"
          state :repair_attempt, default: 0
          state :step_cursor, default: 0
          state :provider_ambiguity, default: 0
          state :check_passed, default: false
          state :session
          state :route if routed
          state :accepted_plan
          state :verification
          state :blocked
          state :terminal
          state :plan_versions, reduce: :append, default: []
          state :plan_reviews, reduce: :append, default: []
          state :approvals, reduce: :append, default: []
          state :effect_intents, reduce: :append, default: []
          state :effect_receipts, reduce: :append, default: []
          state :observations, reduce: :append, default: []
          state :seen_action_signatures, reduce: :append, default: []
          state :seen_failure_signatures, reduce: :append, default: []
          # P11-W / DR-1: the intake's BehaviorTransition claim ids, finalized
          # by the deliberate node after the apply (checkpoint commit).
          state :behavior_transition_claim, reduce: :append, default: []

          node(:intake, implementation_name: "tamoz.agent.session.intake", version: "1") do |state, context|
            nodes.intake(state, context)
          end
          if routed
            node(:route, implementation_name: "tamoz.agent.session.route", version: "1") do |state, context|
              nodes.route(state, context)
            end
          end
          node(:deliberate, implementation_name: "tamoz.agent.session.deliberate", version: "1") do |state, context|
            nodes.deliberate(state, context)
          end
          node(:step_gate, implementation_name: "tamoz.agent.session.step_gate", version: "1") do |state, context|
            nodes.step_gate(state, context)
          end
          node(:step_execute, implementation_name: "tamoz.agent.session.step_execute", version: "1") do |state, context|
            nodes.step_execute(state, context)
          end
          node(:evaluate, implementation_name: "tamoz.agent.session.evaluate", version: "1") do |state, context|
            nodes.evaluate(state, context)
          end
          node(:verify, implementation_name: "tamoz.agent.session.verify", version: "1") do |state, context|
            nodes.verify(state, context)
          end
          node(:terminal, implementation_name: "tamoz.agent.session.terminal", version: "1") do |state, context|
            nodes.terminal(state, context)
          end

          edge Tamoz::START, :intake
          edge :intake, routed ? :route : :deliberate
          edge :verify, :terminal
          edge :terminal, Tamoz::END

          if routed
            branch :route,
                   name: :route_route,
                   version: "1",
                   targets: %i[step_gate deliberate terminal] do |state|
              state.fetch(:next_node).to_sym
            end
          end

          branch :deliberate,
                 name: :deliberate_route,
                 version: "1",
                 targets: %i[step_gate verify terminal] do |state|
            state.fetch(:next_node).to_sym
          end
          branch :step_gate,
                 name: :step_gate_route,
                 version: "1",
                 targets: %i[step_execute evaluate terminal] do |state|
            state.fetch(:next_node).to_sym
          end
          branch :step_execute,
                 name: :step_execute_route,
                 version: "1",
                 targets: %i[evaluate terminal] do |state|
            state.fetch(:next_node).to_sym
          end
          branch :evaluate,
                 name: :evaluate_route,
                 version: "1",
                 targets: %i[step_gate deliberate verify] do |state|
            state.fetch(:next_node).to_sym
          end
        end
      end

      def start(task, thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        run_context = build_run_context(context:, emitter:)
        runner_for(thread).deliver(
          {"task" => String(task)},
          thread:,
          request_id:,
          owner_id: owner_id || SecureRandom.uuid,
          context: run_context
        )
        outcome(thread:, request_id:)
      end

      def resume(answers, thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        guard_state!(thread)
        run_context = build_run_context(context:, emitter:)
        runner_for(thread).deliver(
          answers,
          thread:,
          request_id:,
          operation: :resume,
          owner_id: owner_id || SecureRandom.uuid,
          context: run_context
        )
        outcome(thread:, request_id:)
      end

      def continue(thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        guard_state!(thread)
        run_context = build_run_context(context:, emitter:)
        runner_for(thread).deliver(
          {},
          thread:,
          request_id:,
          operation: :continue,
          owner_id: owner_id || SecureRandom.uuid,
          context: run_context
        )
        outcome(thread:, request_id:)
      end

      def recover(thread:, request_id:, owner_id: nil)
        guard_state!(thread)
        runner_for(thread).recover(
          thread:,
          request_id:,
          owner_id: owner_id || SecureRandom.uuid
        )
        outcome(thread:, request_id:)
      end

      def view(thread:)
        app = app_for_thread(thread)
        snapshot = app.state(thread:)
        state = SessionRecords.load_state!(snapshot.state)
        enforce_graph_binding!(thread, state)
        status = state[:blocked] ? :blocked : snapshot.status
        SessionView.new(
          thread_id: snapshot.thread_id,
          checkpoint_id: snapshot.checkpoint_id,
          sequence: snapshot.sequence,
          execution_id: snapshot.execution_id,
          status:,
          phase: state.fetch(:phase),
          accepted_plan: state[:accepted_plan],
          approvals: state.fetch(:approvals),
          effect_receipts: state.fetch(:effect_receipts),
          blocked: state[:blocked],
          terminal: state[:terminal],
          provider_ambiguity: state.fetch(:provider_ambiguity),
          interrupts: snapshot.interrupts,
          state:
        )
      end

      # Human resolution of an effect the framework refused to guess about. This is the
      # only way a `:unknown` effect leaves that state; nothing automatic can.
      def resolve_effect(thread:, effect_key:, status:, actor:, evidence: {}, namespace: [], owner_id: nil)
        store = app_for_thread(thread).checkpointer
        record = nil
        store.open_writer(
          thread_id: thread,
          namespace:,
          owner_id: owner_id || SecureRandom.uuid,
          ttl: store.writer_ttl
        ) do |writer|
          record = writer.effects.resolve(
            key: effect_key,
            status:,
            actor:,
            evidence:
          )
        end
        record
      end

      def effect(thread:, effect_key:, namespace: [], owner_id: nil)
        store = app_for_thread(thread).checkpointer
        record = nil
        store.open_writer(
          thread_id: thread,
          namespace:,
          owner_id: owner_id || SecureRandom.uuid,
          ttl: store.writer_ttl
        ) { |writer| record = writer.effects.fetch(effect_key) }
        record
      end

      private

      def build_run_context(context:, emitter:)
        cancellation = context&.cancellation || Tamoz::CancellationToken.new
        actual_emitter = emitter || context&.emitter || Tamoz::Emitter::Null::INSTANCE
        return context.with(cancellation:, emitter: actual_emitter) if context

        Tamoz::Context.new(
          run_id: SecureRandom.uuid,
          execution_id: SecureRandom.uuid,
          request_id: SecureRandom.uuid,
          cancellation:,
          emitter: actual_emitter
        )
      end

      # Invariant 18: an unsupported newer record version must fail before any node
      # runs. This is the boundary where that happens for a resumed session.
      # Every durable continuation funnels through here, so the P9 exact-digest
      # replay rule is enforced by the code path rather than by each caller
      # remembering to ask for it.
      def guard_state!(thread)
        state = stored_state(thread)
        return unless state

        enforce_graph_binding!(thread, state)
        enforce_skill_binding!(thread, state)
        enforce_mcp_binding!(thread, state)
        enforce_egress_binding!(thread, state)
        enforce_behavior_binding!(thread, state) if @memory
        state
      end

      def outcome(thread:, request_id:)
        app = app_for_thread(thread)
        runner = app.durable_runner
        request = runner.fetch(thread:, request_id:)
        snapshot = app.state(thread:)
        state = SessionRecords.load_state!(snapshot.state)
        enforce_graph_binding!(thread, state)
        verification = state[:verification]
        result =
          if verification
            Result.new(
              answer: verification.fetch("answer"),
              satisfied: verification.fetch("satisfied"),
              evidence: verification.fetch("evidence"),
              plan: state[:accepted_plan] && Plan.parse(state.fetch(:accepted_plan).fetch("plan")),
              review: nil,
              observations: state.fetch(:observations)
            )
          end
        blocked = state[:blocked]
        status =
          if blocked
            :blocked
          elsif snapshot.status == :paused
            :paused
          elsif snapshot.status == :completed
            :completed
          elsif snapshot.status == :failed
            :failed
          else
            snapshot.status
          end

        SessionOutcome.new(
          status:,
          request_status: request&.status,
          thread_id: snapshot.thread_id,
          execution_id: snapshot.execution_id,
          request_id:,
          approvals: snapshot.interrupts.map(&:descriptor).freeze,
          blocked:,
          result:,
          provider_ambiguity: state.fetch(:provider_ambiguity),
          state:
        )
      end

      def app_for_thread(thread)
        checkpointer = @app.checkpointer
        version = if checkpointer.respond_to?(:latest_graph_version)
                    checkpointer.latest_graph_version(thread_id: thread, namespace: [])
                  else
                    checkpointer.latest(thread_id: thread, namespace: [])&.graph_version
                  end
        version ||= @default_graph_version
        @apps.fetch(version) do
          raise Tamoz::CheckpointVersionError,
                "session #{thread} uses graph version #{version.inspect}; this runtime supports " \
                "#{SUPPORTED_GRAPH_VERSIONS.join(", ")}"
        end
      end
      private :app_for_thread

      def runner_for(thread)
        app_for_thread(thread).durable_runner
      end
      private :runner_for
    end
  end
end
