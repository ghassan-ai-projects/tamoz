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
      :request_id,
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
    ) do
      def adaptive_decisions = state.fetch(:adaptive_decisions, [])
      def lifecycle_events = state.fetch(:lifecycle_events, [])
    end

    # The durable agent lifecycle: one graph turn over the existing DurableRunner,
    # checkpoint store, request inbox, lease/fence, and effect journal.
    #
    # `Session` is durable-only by construction. Ephemeral and read-only work stays on
    # `Tamoz::Agent::Runtime`; PERSISTENCE_DESIGN §9 forbids using the in-memory adapter
    # to claim crash durability or effect safety, so no ephemeral Session is offered.
    class Session
      include SessionContextControls

      MODEL_CALL_SAFETIES = %i[idempotent unsafe].freeze
      WORK_STEP_HEADROOM = 20
      ROUTINGS = %i[legacy experimental adaptive work].freeze
      GRAPH_VERSION_BY_ROUTING = {
        legacy: GraphVersions::COMPACTION_GRAPH_VERSION,
        experimental: GraphVersions::CURRENT_GRAPH_VERSION,
        adaptive: GraphVersions::ADAPTIVE_GRAPH_VERSION,
        work: GraphVersions::WORK_GRAPH_VERSION
      }.freeze

      attr_reader :app, :definition, :toolbox, :model

      # P15-W: the sealed P18 capability host this session was constructed
      # with. Exposed read-only so an operator (and the audit) can inspect the
      # exact surface a thread is bound to without reaching into the nodes.
      def capabilities = nodes_for_default_graph.capabilities

      def initialize(**arguments)
        options = Options.build(**arguments)
        @toolbox = options.toolbox
        @model = options.model
        @mcp = options.mcp
        # P11: the optional memory surface. Nil keeps every memory branch
        # inert (pre-P11 sessions resume byte-identically).
        @memory = options.memory
        @profile = options.profile
        @approval_engine = options.approval_engine
        @approval_session_id = options.approval_session_id
        # Shared state of the included SessionContextControls module.
        @artifact_store = options.artifact_store
        @artifact_tenant = options.artifact_tenant
        @default_graph_version = options.default_graph_version
        transcript_reader = lambda do |thread_id:, request_id:|
          conversation_transcript(thread_id:, request_id:)
        end
        previous_turn_reader = lambda do |thread_id:, execution_id:|
          previous_turn_state(thread_id:, execution_id:)
        end
        @nodes_by_version = build_nodes(options.node_arguments(transcript_reader:, previous_turn_reader:))
        @definitions = build_definitions(@nodes_by_version)
        @apps = @definitions.to_h do |version, definition|
          [version, definition.compile(checkpointer: options.checkpointer, **graph_limits(version, options.harness))]
        end.freeze
        @definition = @definitions.fetch(@default_graph_version)
        @app = @apps.fetch(@default_graph_version)
        @runner = @app.durable_runner
        freeze
      end

      # One SessionNodes collaborator set per declared graph variant.
      def build_nodes(node_arguments)
        {
          GraphVersions::GRAPH_VERSION => SessionNodes.new(
            **node_arguments, graph_version: GraphVersions::GRAPH_VERSION
          ),
          GraphVersions::CURRENT_GRAPH_VERSION => SessionNodes.new(
            **node_arguments, graph_version: GraphVersions::CURRENT_GRAPH_VERSION
          ),
          GraphVersions::ADAPTIVE_GRAPH_VERSION => SessionNodes.new(
            **node_arguments, graph_version: GraphVersions::ADAPTIVE_GRAPH_VERSION
          ),
          GraphVersions::COMPACTION_GRAPH_VERSION => SessionNodes.new(
            **node_arguments, graph_version: GraphVersions::COMPACTION_GRAPH_VERSION
          ),
          GraphVersions::WORK_GRAPH_VERSION => SessionNodes.new(
            **node_arguments, graph_version: GraphVersions::WORK_GRAPH_VERSION
          )
        }.freeze
      end
      private :build_nodes

      def build_definitions(nodes_by_version)
        nodes_by_version.to_h do |version, nodes|
          [version, SessionGraph.definition_for(nodes, version)]
        end.freeze
      end
      private :build_definitions

      # The loop budget, not the graph backstop, must end a work turn. Worst case per model call: an
      # overflow retry, the step, a full message of gated and executed calls, the closing gate, observe.
      def graph_limits(version, harness)
        return {} unless version == GraphVersions::WORK_GRAPH_VERSION

        policy = WorkContext::Settings.from(harness).loop_policy
        steps = ((5 + (2 * Harness::ToolCalls::MAX_PER_STEP)) * policy.max_model_calls) + WORK_STEP_HEADROOM
        { limits: Graph::Limits.new(max_steps: [Tamoz.configuration.recursion_limit, steps].max) }
      end
      private :graph_limits

      def nodes_for_default_graph
        @nodes_by_version.fetch(@default_graph_version)
      end

      # P8 §5.2 note: the toolbox/profile surface check itself lives on
      # Session::Options — construction validation is in one place.

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
        verify_binding!(thread) { |stored| enforce_skill_binding!(thread, stored) }
      end

      # P10 §5 epoch rules: a resumed session must bind the exact MCP catalog
      # digests it was planned against. A digest mismatch stops with the typed
      # `McpCatalogSnapshotUnavailableError` — no silent schema substitution. The
      # same guard shape as `verify_skill_binding!`: legacy sessions (no
      # `mcp_catalogs` → `{}`) and MCP-free sessions share the empty pin, so a
      # pre-P10 session and a session built without an MCP source resume
      # identically, and every mismatch fails closed.
      def verify_mcp_binding!(thread:)
        verify_binding!(thread) { |stored| enforce_mcp_binding!(thread, stored) }
      end

      # P17 (correction 5): a resumed session must bind the exact egress
      # declaration it was planned under. A mismatch stops with the typed
      # `EgressBindingUnavailableError` — a changed egress declaration is a
      # changed network policy (invariant 35/36), so there is no degraded
      # read-only continuation. The empty pin `{}` covers both the pre-P17
      # session and the "profile has no egress section" state, so sessions that
      # never declared egress resume identically.
      def verify_egress_binding!(thread:)
        verify_binding!(thread) { |stored| enforce_egress_binding!(thread, stored) }
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

        verify_binding!(thread) { |stored| enforce_behavior_binding!(thread, stored) }
      end

      # The one guard wrapper every `verify_*_binding!` entry point rides: load
      # the stored state, run the specific enforcement, and treat a thread with
      # no checkpoint as nothing to protect (intake will write the current
      # epoch). Every other failure — corruption, an unsupported record
      # version — propagates, because a guard that swallows an unreadable
      # record fails *open*, the opposite of what invariant 41 asks for.
      def verify_binding!(thread)
        stored = stored_state(thread)
        yield(stored) if stored
        nil
      end
      private :verify_binding!

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
        return if GraphVersions::SUPPORTED_GRAPH_VERSIONS.include?(stored)

        raise Tamoz::CheckpointVersionError,
              "session #{thread} uses graph version #{stored.inspect}; this runtime supports " \
              "#{GraphVersions::SUPPORTED_GRAPH_VERSIONS.join(", ")}. Start a new session or use a compatible runtime."
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
        stored_sources = record.fetch("mcp_source_digests", {})
        current_sources = @mcp ? @mcp.mcp_source_digests : {}
        return if stored == current && stored_sources == current_sources

        raise McpCatalogSnapshotUnavailableError,
              "session #{thread} was planned against MCP catalog/source digests " \
              "#{stored.inspect}/#{stored_sources.inspect}; the current source exposes " \
              "#{current.inspect}/#{current_sources.inspect}. Restore the exact MCP " \
              "configuration or start a new session."
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
        return {} unless @profile&.egress

        Tamoz::Agent::Deliberation.canonical(@profile.egress)
      end
      private :current_egress_pin

      # Reads the conversation transcript a channel turn carries, through the
      # compiled app's BOUND checkpointer (what arrives at the constructor is
      # the unbound adapter). ONE authoritative stream serves both sides of
      # the truncation contract: the thread-scoped durable turn fragments are
      # what /reset and /compact count, and the same stream minus the latest
      # truncating control's cumulative prefix is what every later frame
      # composes — so the report's counts and the actual composition can
      # never disagree across windows.
      def conversation_transcript(thread_id:, request_id:)
        state = stored_state(thread_id)
        offset = SessionContextControls.visible_fragment_offset(Array(state[:context_controls])) if state
        fragments = SessionPlanningContext.conversation_history(@app.checkpointer, thread_id:)
        offset ? fragments.drop(offset) : fragments
      end
      private :conversation_transcript

      # The final state of the thread's latest other execution: what a work turn carries forward.
      def previous_turn_state(thread_id:, execution_id:)
        app = app_for_thread(thread_id)
        earlier = app.checkpointer.history(thread_id:, limit: 200, namespace: [])
                     .find { |checkpoint| checkpoint.execution_id != execution_id }
        earlier && SessionRecords.load_state!(app.snapshot(earlier).state)
      end
      private :previous_turn_state

      def start(task, thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        deliver_turn({"task" => String(task)}, thread:, request_id:, owner_id:, emitter:, context:)
      end

      def resume(answers, thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        guard_state!(thread)
        deliver_turn(answers, thread:, request_id:, operation: :resume, owner_id:, emitter:, context:)
      end

      def continue(thread:, request_id:, owner_id: nil, emitter: nil, context: nil)
        guard_state!(thread)
        deliver_turn({}, thread:, request_id:, operation: :continue, owner_id:, emitter:, context:)
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

      # ADR §2.3: a session that ends deletes its grant rows — grants never
      # outlive the session they were remembered for.
      def close
        @approval_engine&.close_session(@approval_session_id) if @approval_session_id
        nil
      end

      def view(thread:)
        app = app_for_thread(thread)
        snapshot = app.state(thread:)
        state = SessionRecords.load_state!(snapshot.state)
        enforce_graph_binding!(thread, state)
        status = lifecycle_status(snapshot.status, blocked: state[:blocked])
        SessionView.new(
          thread_id: snapshot.thread_id,
          checkpoint_id: snapshot.checkpoint_id,
          sequence: snapshot.sequence,
          execution_id: snapshot.execution_id,
          request_id: request_id_for(app, thread:, execution_id: snapshot.execution_id),
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
        with_effect_writer(thread, namespace:, owner_id:) do |effects|
          effects.resolve(key: effect_key, status:, actor:, evidence:)
        end
      end

      def effect(thread:, effect_key:, namespace: [], owner_id: nil)
        with_effect_writer(thread, namespace:, owner_id:) { |effects| effects.fetch(effect_key) }
      end

      private

      def request_id_for(app, thread:, execution_id:)
        return nil unless execution_id

        app.durable_runner.history(thread:).reverse_each do |request|
          return request.request_id if request.execution_id == execution_id
        end
        nil
      end

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

      def deliver_turn(payload, thread:, request_id:, owner_id:, emitter:, context:, operation: :turn)
        run_context = build_run_context(context:, emitter:)
        runner_for(thread).deliver(
          payload,
          thread:,
          request_id:,
          operation:,
          owner_id: owner_id || SecureRandom.uuid,
          context: run_context
        )
        outcome(thread:, request_id:)
      end

      def with_effect_writer(thread, namespace:, owner_id:)
        store = app_for_thread(thread).checkpointer
        record = nil
        store.open_writer(
          thread_id: thread,
          namespace:,
          owner_id: owner_id || SecureRandom.uuid,
          ttl: store.writer_ttl
        ) { |writer| record = yield(writer.effects) }
        record
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
        blocked = state[:blocked]
        result = verification_result(state)
        status = lifecycle_status(snapshot.status, blocked:)

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

      def verification_result(state)
        verification = state[:verification]
        return nil unless verification

        Result.new(
          answer: verification.fetch("answer"),
          satisfied: verification.fetch("satisfied"),
          evidence: verification.fetch("evidence"),
          plan: state[:accepted_plan] && Plan.parse(state.fetch(:accepted_plan).fetch("plan")),
          review: nil,
          observations: state.fetch(:observations)
        )
      end

      def lifecycle_status(snapshot_status, blocked:)
        blocked ? :blocked : snapshot_status
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
                "#{GraphVersions::SUPPORTED_GRAPH_VERSIONS.join(", ")}"
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
