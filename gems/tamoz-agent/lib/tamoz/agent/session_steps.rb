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
      Preparation = Data.define(:intent, :arguments, :preview, :approval_required, :decision)

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

        prepared = prepare_step(state, step, tool, accepted, context)
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
        outcome = @services.effects.dispatch(
          context, intent, step,
          iteration: state.fetch(:step_cursor), sub_operation: 0
        )
        handle_outcome(state, step, intent, outcome)
      end

      private

      def prepare_step(state, step, tool, accepted, context)
        effects = @services.effects
        prepare_step_without_rescue(effects, state, step, tool, accepted, context)
      rescue ToolArgumentError => e
        argument_failure(state, step, tool, e)
      end

      def prepare_step_without_rescue(effects, state, step, tool, accepted, context)
        arguments = effects.resolved_effect_arguments(step.fetch('arguments'), tool)
        iteration = state.fetch(:step_cursor)
        budget = effects.maximum_effect_output_bytes(tool)
        if @services.evidence.observation_bytes(state) + budget > SessionNodes::MAX_OBSERVATION_BYTES
          raise ToolError, "insufficient observation budget for #{tool}"
        end

        intent = effects.build_intent(step, accepted, arguments, iteration:)

        # ADR §8: a replayed gate re-reads its journaled verdict instead of
        # asking again — decide must never run twice for one gated step.
        case journaled_verdict(state, accepted, step)
        when 'approve' then return no_approval_preparation(intent, arguments)
        when 'deny' then return denied_update(state, step, nil)
        end

        decision = effects.decide_step_tool(
          tool: tool,
          arguments: arguments,
          session_id: @services.configuration.approval_session_id,
          step_scope: "#{context.execution_id}.#{accepted.fetch('plan_id')}.#{step.fetch('id')}"
        )
        case decision.verdict
        when :allow then return no_approval_preparation(intent, arguments)
        when :deny then return denied_update(state, step, decision)
        end

        Preparation.new(
          intent:,
          arguments:,
          preview: effects.preview_for(tool, arguments),
          approval_required: true,
          decision:
        )
      end

      def no_approval_preparation(intent, arguments)
        Preparation.new(intent:, arguments:, preview: nil, approval_required: false, decision: nil)
      end

      # A deny is a structured tool result fed back to the model; the turn
      # continues (ADR §2.4) — the workspace was not touched.
      def denied_update(state, step, decision)
        reason = decision ? "#{decision.reason}, rule #{decision.rule_id}" : 'denied by operator'
        @services.evidence.tool_failure_update(
          state,
          failure: SessionEvidence::ToolFailure.new(
            step:,
            tool: step['tool'],
            error_class: 'ToolPolicyError',
            reason: "denied: #{reason}",
            effect_receipt: nil
          )
        )
      end

      def journaled_verdict(state, accepted, step)
        record = state.fetch(:approvals, []).find do |entry|
          entry['approval_id'] == "#{accepted.fetch('plan_id')}.#{step.fetch('id')}"
        end
        record && record['decision']
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
          'decision' => {
            'id' => prepared.decision.id,
            'verdict' => prepared.decision.verdict.to_s,
            'reason' => prepared.decision.reason,
            'rule_id' => prepared.decision.rule_id,
            'required_evidence' => prepared.decision.required_evidence&.to_s,
            'grant_scopes' => prepared.decision.grant_offer&.scopes&.map(&:to_s)
          },
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
          logical_key: outcome.effect_key,
          attempt_identity: attempt_identity(outcome),
          step_id: step.fetch('id'),
          operation: intent.fetch('operation'),
          safety: intent.fetch('safety'),
          status: 'failed',
          attempt_number: outcome.attempt_number,
          reconciliation: outcome.reconciliation,
          iteration: intent.fetch('iteration', 0),
          sub_operation: intent.fetch('sub_operation', 0)
        )
      end

      def successful_update(state, step, intent, outcome)
        output = String(outcome.value.fetch('output'))
        ensure_observation_budget(state, output)
        update = {
          step_cursor: state.fetch(:step_cursor) + 1,
          next_node: 'evaluate',
          observations: [successful_observation(state, step, intent, outcome)],
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

      # rubocop:disable Metrics/AbcSize -- this maps the complete observation wire
      # contract at one persistence boundary.
      def successful_observation(state, step, intent, outcome)
        value = outcome.value
        output = String(value.fetch('output'))
        fields = {
          phase: state.fetch(:phase),
          repair_attempt: state.fetch(:repair_attempt),
          step_id: step.fetch('id'),
          output:,
          tool: step['tool'],
          effect_key: outcome.effect_key,
          iteration: intent.fetch('iteration', 0),
          sub_operation: intent.fetch('sub_operation', 0),
          provenance: value.fetch('provenance', 'workspace'),
          truncated: value.fetch('truncated', false),
          output_bytes: value.fetch('output_bytes', output.bytesize)
        }
        fields[:source_id] = value.fetch('source_id') if value.key?('source_id')
        fields[:check] = outcome.value.fetch('check') if outcome.value.key?('check')
        SessionRecords.build('observation', **fields)
      end
      # rubocop:enable Metrics/AbcSize

      def successful_receipt(step, intent, outcome)
        SessionRecords.build(
          'effect_receipt',
          effect_key: outcome.effect_key,
          logical_key: outcome.effect_key,
          attempt_identity: attempt_identity(outcome),
          step_id: step.fetch('id'),
          operation: intent.fetch('operation'),
          safety: intent.fetch('safety'),
          status: 'succeeded',
          attempt_number: outcome.attempt_number,
          reconciliation: outcome.reconciliation,
          iteration: intent.fetch('iteration', 0),
          sub_operation: intent.fetch('sub_operation', 0)
        )
      end

      def attempt_identity(outcome)
        outcome.attempt_identity || "#{outcome.effect_key}/attempt/#{outcome.attempt_number}"
      end
    end
  end
end
