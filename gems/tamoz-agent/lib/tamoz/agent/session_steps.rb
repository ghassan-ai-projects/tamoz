# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Gates, dispatches, and records the steps in an accepted plan.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:LongParameterList :reek:NilCheck :reek:TooManyMethods :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction
    # Step helpers preserve approval, digest, effect, and observation ordering.
    class SessionSteps
      # Immutable preflight result used by the approval boundary.
      Preparation = Data.define(:intent, :arguments, :preview, :approval_required)

      def initialize(services:)
        @services = services
      end

      def step_gate(state, context)
        accepted = state.fetch(:accepted_plan)
        steps = accepted.fetch('plan').fetch('steps')
        cursor = state.fetch(:step_cursor)
        return { next_node: 'evaluate' } if cursor >= steps.length

        step = steps.fetch(cursor)
        tool = step['tool']
        return { next_node: 'step_execute' } if tool.nil?

        prepared = prepare_step(state, step, tool, accepted)
        return prepared if prepared.is_a?(Hash)
        return execute_without_approval(prepared) unless prepared.approval_required

        approval_update(state, context, accepted, step, prepared)
      end

      def step_execute(state, context)
        accepted = state.fetch(:accepted_plan)
        step = accepted.fetch('plan').fetch('steps').fetch(state.fetch(:step_cursor))
        return no_tool_update(state, step) if step['tool'].nil?

        evidence = @services.evidence
        intent = evidence.find_intent(state, accepted, step)
        outcome = @services.effects.dispatch(context, intent, step)
        handle_outcome(state, step, intent, outcome)
      end

      private

      def prepare_step(state, step, tool, accepted)
        effects = @services.effects
        prepare_step_without_rescue(effects, state, step, tool, accepted)
      rescue ToolArgumentError => e
        argument_failure(state, step, tool, e)
      end

      def prepare_step_without_rescue(effects, state, step, tool, accepted)
        arguments = effects.resolved_effect_arguments(step.fetch('arguments'), tool)
        intent = effects.build_intent(step, accepted, arguments)
        return no_approval_preparation(intent, arguments) unless effects.approval_required?(tool)

        budget = effects.maximum_effect_output_bytes(tool)
        if @services.evidence.observation_bytes(state) + budget > SessionNodes::MAX_OBSERVATION_BYTES
          raise ToolError, "insufficient observation budget for #{tool}"
        end

        Preparation.new(
          intent:,
          arguments:,
          preview: effects.preview_for(tool, arguments),
          approval_required: true
        )
      end

      def no_approval_preparation(intent, arguments)
        Preparation.new(intent:, arguments:, preview: nil, approval_required: false)
      end

      def argument_failure(state, step, tool, error)
        @services.evidence.tool_failure_update(
          state,
          failure: SessionEvidence::ToolFailure.new(
            step:,
            tool:,
            error_class: Tamoz::Core.serialized_tool_error_name(error.class.name),
            reason: error.message,
            effect_receipt: nil
          )
        )
      end

      def execute_without_approval(prepared)
        { next_node: 'step_execute', effect_intents: [prepared.intent] }
      end

      def approval_update(state, context, accepted, step, prepared)
        preview_digest = Digest::SHA256.hexdigest(prepared.preview)
        answer = Tamoz.interrupt(
          approval_descriptor(state, accepted, step, prepared, preview_digest),
          context
        )
        granted = [true, 'approve', 'approved'].include?(answer)
        approval = approval_record(accepted, step, prepared, preview_digest, granted)
        return { approvals: [approval], next_node: 'terminal', terminal_reason: 'approval_denied' } unless granted

        { approvals: [approval], effect_intents: [prepared.intent], next_node: 'step_execute' }
      end

      def approval_descriptor(state, accepted, step, prepared, preview_digest)
        {
          'kind' => 'approve_tool',
          'session_id' => state.fetch(:session).fetch('session_id'),
          'plan_id' => accepted.fetch('plan_id'),
          'plan_digest' => accepted.fetch('plan_digest'),
          'step_id' => step.fetch('id'),
          'tool' => step['tool'],
          'arguments' => prepared.arguments,
          'preview' => prepared.preview,
          'arguments_digest' => prepared.intent.fetch('arguments_digest'),
          'preview_digest' => preview_digest
        }
      end

      def approval_record(accepted, step, prepared, preview_digest, granted)
        SessionRecords.build(
          'approval',
          approval_id: "#{accepted.fetch('plan_id')}.#{step.fetch('id')}",
          plan_id: accepted.fetch('plan_id'),
          plan_digest: accepted.fetch('plan_digest'),
          step_id: step.fetch('id'),
          tool: step['tool'],
          arguments_digest: prepared.intent.fetch('arguments_digest'),
          preview_digest:,
          decision: granted ? 'approve' : 'deny'
        )
      end

      def no_tool_update(state, step)
        {
          step_cursor: state.fetch(:step_cursor) + 1,
          next_node: 'evaluate',
          observations: [
            SessionRecords.build(
              'observation',
              phase: state.fetch(:phase),
              repair_attempt: state.fetch(:repair_attempt),
              step_id: step.fetch('id'),
              output: 'No tool required.'
            )
          ]
        }
      end

      def handle_outcome(state, step, intent, outcome)
        case outcome.status
        when :unknown
          return @services.evidence.blocked_update(
            outcome,
            'effect outcome is unknown',
            step_id: step.fetch('id'),
            operation: intent.fetch('operation')
          )
        when :wait
          raise LeaseLostError, "another owner still holds effect #{outcome.effect_key}"
        when :failed
          return failed_update(state, step, intent, outcome)
        end
        successful_update(state, step, intent, outcome)
      end

      def failed_update(state, step, intent, outcome)
        evidence = @services.evidence
        raise ToolError, evidence.tool_error_message(outcome) unless evidence.repairable_outcome?(outcome)

        evidence.tool_failure_update(
          state,
          failure: SessionEvidence::ToolFailure.new(
            step:,
            tool: step['tool'],
            error_class: evidence.tool_error_class(outcome),
            reason: evidence.tool_error_message(outcome),
            effect_receipt: failed_receipt(step, intent, outcome)
          )
        )
      end

      def failed_receipt(step, intent, outcome)
        SessionRecords.build(
          'effect_receipt',
          effect_key: outcome.effect_key,
          step_id: step.fetch('id'),
          operation: intent.fetch('operation'),
          safety: intent.fetch('safety'),
          status: 'failed',
          attempt_number: outcome.attempt_number,
          reconciliation: outcome.reconciliation
        )
      end

      def successful_update(state, step, intent, outcome)
        output = String(outcome.value.fetch('output'))
        ensure_observation_budget(state, output)
        update = {
          step_cursor: state.fetch(:step_cursor) + 1,
          next_node: 'evaluate',
          observations: [successful_observation(state, step, output, outcome)],
          effect_receipts: [successful_receipt(step, intent, outcome)]
        }
        update[:check_passed] = outcome.value.fetch('check').fetch('passed') if outcome.value.key?('check')
        update
      end

      def ensure_observation_budget(state, output)
        return if @services.evidence.observation_bytes(state) + output.bytesize <=
                  SessionNodes::MAX_OBSERVATION_BYTES

        raise ToolError, "tool observations exceed #{SessionNodes::MAX_OBSERVATION_BYTES} bytes"
      end

      def successful_observation(state, step, output, outcome)
        fields = {
          phase: state.fetch(:phase),
          repair_attempt: state.fetch(:repair_attempt),
          step_id: step.fetch('id'),
          output:,
          tool: step['tool']
        }
        fields[:check] = outcome.value.fetch('check') if outcome.value.key?('check')
        SessionRecords.build('observation', **fields)
      end

      def successful_receipt(step, intent, outcome)
        SessionRecords.build(
          'effect_receipt',
          effect_key: outcome.effect_key,
          step_id: step.fetch('id'),
          operation: intent.fetch('operation'),
          safety: intent.fetch('safety'),
          status: 'succeeded',
          attempt_number: outcome.attempt_number,
          reconciliation: outcome.reconciliation
        )
      end
    end
  end
end
