# frozen_string_literal: true

module Tamoz
  module Agent
    # Routes evaluation, verification, and terminal memory admission.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyStatements :reek:UtilityFunction
    # The three graph phases share state because their routing is one protocol.
    class SessionLifecycle
      # Immutable inputs for the verification model prompt.
      VerificationInput = Data.define(
        :state, :plan, :review, :observations, :context, :planning_context, :compaction, :terminal_reason
      )

      def initialize(services:)
        @services = services
      end

      def evaluate(state, _context)
        accepted = state.fetch(:accepted_plan)
        steps = accepted.fetch('plan').fetch('steps')
        cursor = state.fetch(:step_cursor)
        evidence = @services.evidence
        check = evidence.current_pass_check(state)
        failure = evidence.current_pass_tool_failure(state)
        return failure_update(state, failure) if failure
        return check_update(state, check) if check
        return { next_node: 'step_gate' } if cursor < steps.length

        completion_update(state)
      end

      def verify(state, context)
        configuration = @services.configuration
        input = verification_input(state, configuration, context)
        call = verification_call(context, input)
        return @services.evidence.blocked_update(call, 'model call outcome is unknown') unless
          call.status == :succeeded

        update = verification_update(state, configuration, call, input.terminal_reason)
        input.compaction && compaction_state_supported? ? update.merge(compactions: [input.compaction]) : update
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- terminal assembly
      # is the single durable boundary for the completed session and its lifecycle.
      def terminal(state, context)
        verification = state[:verification]
        @services.memory.record_episode_memory(state, verification) if @services.configuration.memory
        update = {
          phase: 'terminal',
          terminal: SessionRecords.build(
            'terminal',
            reason: state.fetch(:terminal_reason),
            satisfied: verification ? verification.fetch('satisfied') : false,
            blocked: state[:blocked]
          )
        }
        return update unless state.key?(:lifecycle_events)

        update.merge(
          lifecycle_events: [
            SessionRecords.build(
              'lifecycle_event',
              event_type: 'terminal',
              sequence: state.fetch(:lifecycle_events).length,
              request_id: context.request_id,
              thread_id: context.thread_id || state.dig(:session, 'session_id'),
              execution_id: context.execution_id,
              phase: 'terminal',
              effect_state: state[:blocked] ? 'unknown' : 'terminal',
              delivery_state: 'pending',
              terminal_reason: state.fetch(:terminal_reason)
            )
          ]
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def failure_update(state, failure)
        @services.evidence.bounded_repair(
          state,
          failure.fetch('failure_signature'),
          repeated_reason: 'repeated_tool_failure'
        )
      end

      def check_update(state, check)
        return { next_node: 'verify', terminal_reason: 'check_passed' } if check.fetch('passed')

        @services.evidence.failed_check(state, check)
      end

      def completion_update(state)
        case state.fetch(:phase)
        when 'discovery'
          next_phase = state.dig(:route, 'route') == 'read_only_work' ? 'read_only' : 'action'
          { next_node: 'deliberate', phase: next_phase, step_cursor: 0 }
        when 'read_only'
          { next_node: 'verify', terminal_reason: 'completed' }
        else
          { next_node: 'verify', terminal_reason: 'completed_without_check' }
        end
      end

      def verification_context(configuration, state, terminal_reason)
        return {} unless configuration.toolbox.action_capable?

        {
          'configured_check_passed' => state.fetch(:check_passed),
          'terminal_reason' => terminal_reason
        }
      end

      def verification_input(state, configuration, durable_context)
        accepted = state.fetch(:accepted_plan)
        plan = Plan.parse(accepted.fetch('plan'))
        review = @services.evidence.last_semantic_review(state, accepted)
        observations = state.fetch(:observations).map do |record|
          @services.evidence.observation_payload(record)
        end
        compacted = @services.planning_context.compact_for(
          state,
          :verify,
          observations:,
          compaction: { effects: @services.effects, durable_context: }
        )
        terminal_reason = state.fetch(:terminal_reason)
        context = verification_context(configuration, state, terminal_reason)
        VerificationInput.new(
          state:, plan:, review:, observations: compacted.observations, context:,
          planning_context: compacted.context, compaction: compacted.record, terminal_reason:
        )
      end

      def verification_call(context, input)
        @services.effects.model_call(
          context,
          stage: :verify,
          system: Tamoz::Agent::Deliberation::VERIFY_SYSTEM,
          prompt: Tamoz::Agent::Deliberation.verification_prompt(
            input.state.fetch(:task),
            input.plan,
            input.review,
            input.observations,
            verification_context: input.context,
            planning_context: input.planning_context
          ),
          call_index: 0
        )
      end

      def compaction_state_supported?
        @services.configuration.graph_version != SessionNodes::GRAPH_VERSION
      end

      def verification_update(state, configuration, call, terminal_reason)
        document = Tamoz::Agent::Deliberation.parse_verification(call.value)
        satisfied = document.fetch('satisfied')
        evidence = document.fetch('evidence')
        satisfied, evidence = enforce_check_requirement(state, configuration, terminal_reason, satisfied, evidence)

        {
          next_node: 'terminal',
          provider_ambiguity: state.fetch(:provider_ambiguity) + (call.attempt_number > 1 ? 1 : 0),
          verification: SessionRecords.build(
            'verification',
            answer: document.fetch('answer'),
            satisfied:,
            evidence:,
            configured_check_passed: state.fetch(:check_passed) == true,
            terminal_reason:
          )
        }
      end

      def enforce_check_requirement(state, configuration, terminal_reason, satisfied, evidence)
        return [satisfied, evidence] unless configuration.toolbox.action_capable?
        return [satisfied, evidence] if configuration.toolbox.checks.empty?
        return [satisfied, evidence] if state.fetch(:check_passed) == true

        [false, evidence + ["framework: no configured check passed (#{terminal_reason})"]]
      end
    end
  end
end
