# frozen_string_literal: true

module Tamoz
  module Agent
    # Orchestrates the bounded plan/review loop for one durable phase.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements :reek:UtilityFunction
    # These helpers keep the ordered durable loop visible and deterministic.
    class SessionDeliberation
      # Immutable prompt and review state shared across plan attempts.
      LoopState = Data.define(
        :phase,
        :repair_attempt,
        :task,
        :evidence,
        :allowed_tools,
        :mcp_tools,
        :planning_context,
        :feedback,
        :plans,
        :reviews,
        :ambiguity
      )

      def initialize(services:)
        @services = services
        @attempt = SessionPlanAttempt.new(services:)
      end

      def deliberate(state, context)
        return {} if cancelled?(state)

        @services.memory.finalize_behavior_claim(state)
        conversation = @services.planning_context.conversation_transcript(context)
        loop_state, compaction = build_loop_state(state, context, conversation)
        update = run_attempts(state, context, loop_state)
        compaction ? update.merge(compactions: [compaction]) : update
      end

      private

      def cancelled?(state)
        state.fetch(:next_node) == 'terminal' &&
          state.fetch(:terminal_reason) == 'cancelled_by_user'
      end

      # rubocop:disable Metrics/MethodLength -- one ordered planner-context assembly.
      def build_loop_state(state, context, conversation)
        phase = state.fetch(:phase).to_sym
        effects = @services.effects
        evidence = state.fetch(:observations).map { |record| observation_payload(record) }
        allowed_tools = effects.allowed_tool_names(phase)
        mcp_tools = effects.mcp_planning_surface(allowed_tools)
        compaction = { effects:, durable_context: context }
        compacted = @services.planning_context.compact_for(
          state,
          phase,
          conversation:,
          observations: evidence,
          compaction:
        )
        [LoopState.new(
          phase:,
          repair_attempt: state.fetch(:repair_attempt),
          task: state.fetch(:task),
          evidence: compacted.observations,
          allowed_tools:,
          mcp_tools:,
          planning_context: compacted.context,
          feedback: [],
          plans: [],
          reviews: [],
          ambiguity: state.fetch(:provider_ambiguity)
        ), compacted.record]
      end
      # rubocop:enable Metrics/MethodLength

      def observation_payload(record)
        @services.evidence.observation_payload(record)
      end

      def run_attempts(state, context, loop_state)
        @services.configuration.max_plan_attempts.times do |offset|
          details = attempt_details(loop_state, offset + 1)
          result = @attempt.run(state, context, details:)
          return result.update if result.update

          loop_state = next_loop_state(loop_state, result)
        end
        rejected_plan(state, loop_state)
      end

      def next_loop_state(loop_state, result)
        loop_state.with(
          feedback: result.feedback,
          plans: result.plans,
          reviews: result.reviews,
          ambiguity: result.ambiguity
        )
      end

      def rejected_plan(state, loop_state)
        @services.plan_outcomes.plan_rejected(
          state,
          rejection: SessionPlanOutcomes::Rejection.new(
            plans: loop_state.plans,
            reviews: loop_state.reviews,
            ambiguity: loop_state.ambiguity,
            phase: loop_state.phase,
            repair_attempt: loop_state.repair_attempt
          )
        )
      end

      def attempt_details(loop_state, attempt)
        SessionPlanAttempt::Details.new(
          attempt:,
          phase: loop_state.phase,
          repair_attempt: loop_state.repair_attempt,
          task: loop_state.task,
          evidence: loop_state.evidence,
          allowed_tools: loop_state.allowed_tools,
          mcp_tools: loop_state.mcp_tools,
          planning_context: loop_state.planning_context,
          feedback: loop_state.feedback,
          plans: loop_state.plans,
          reviews: loop_state.reviews,
          ambiguity: loop_state.ambiguity
        )
      end
    end
  end
end
