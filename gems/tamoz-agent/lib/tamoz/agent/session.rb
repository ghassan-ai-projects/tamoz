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
      MODEL_CALL_SAFETIES = %i[idempotent unsafe].freeze

      attr_reader :app, :definition, :toolbox

      def initialize(
        model:,
        toolbox:,
        checkpointer:,
        max_plan_attempts: 3,
        max_repair_attempts: Runtime::MAX_REPAIR_ATTEMPTS,
        model_call_safety: :idempotent,
        profile: nil
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
        unless checkpointer.respond_to?(:durable?) && checkpointer.durable?
          raise ConfigurationError,
                "Tamoz::Agent::Session requires a durable checkpointer; use " \
                "Tamoz::Agent::Runtime for ephemeral work"
        end

        @toolbox = toolbox
        verify_profile_binding!(profile)
        @nodes = SessionNodes.new(
          model:,
          toolbox:,
          max_plan_attempts:,
          max_repair_attempts:,
          model_call_safety:,
          profile:
        )
        @definition = Session.build_definition(@nodes)
        @app = @definition.compile(checkpointer:)
        @runner = @app.durable_runner
        freeze
      end

      # P8 §5.2: the toolbox must expose exactly the capability surface the
      # profile pins; a mismatch fails here, before any model I/O.
      def verify_profile_binding!(profile)
        return unless profile

        expected = profile.policy.fetch("tool_catalog_digest")
        unless toolbox.catalog_digest == expected
          raise Profile::ValidationError,
                "toolbox catalog digest #{toolbox.catalog_digest} does not match " \
                "profile #{profile.profile_id.inspect} policy.tool_catalog_digest #{expected}"
        end
        unless toolbox.root.to_s == File.expand_path(profile.canonical_root)
          raise Profile::ValidationError,
                "toolbox root #{toolbox.root} does not match profile canonical_root " \
                "#{profile.canonical_root.inspect}"
        end
      end
      private :verify_profile_binding!

      def self.build_definition(nodes)
        Tamoz.graph(name: GRAPH_NAME, version: GRAPH_VERSION) do
          state :task, default: ""
          state :phase, default: ""
          state :next_node, default: "intake"
          state :terminal_reason, default: "no_check"
          state :repair_attempt, default: 0
          state :step_cursor, default: 0
          state :provider_ambiguity, default: 0
          state :check_passed, default: false
          state :session
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

          node(:intake, implementation_name: "tamoz.agent.session.intake", version: "1") do |state, context|
            nodes.intake(state, context)
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
          edge :intake, :deliberate
          edge :verify, :terminal
          edge :terminal, Tamoz::END

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
        @runner.deliver(
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
        @runner.deliver(
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
        @runner.deliver(
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
        @runner.recover(
          thread:,
          request_id:,
          owner_id: owner_id || SecureRandom.uuid
        )
        outcome(thread:, request_id:)
      end

      def view(thread:)
        snapshot = @app.state(thread:)
        state = SessionRecords.load_state!(snapshot.state)
        SessionView.new(
          thread_id: snapshot.thread_id,
          checkpoint_id: snapshot.checkpoint_id,
          sequence: snapshot.sequence,
          execution_id: snapshot.execution_id,
          status: snapshot.status,
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
        store = @app.checkpointer
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
        store = @app.checkpointer
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
      def guard_state!(thread)
        snapshot = @app.checkpointer.latest(thread_id: thread, namespace: [])
        return unless snapshot

        SessionRecords.load_state!(@app.snapshot(snapshot).state)
      end

      def outcome(thread:, request_id:)
        request = @runner.fetch(thread:, request_id:)
        snapshot = @app.state(thread:)
        state = snapshot.state
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
    end
  end
end
