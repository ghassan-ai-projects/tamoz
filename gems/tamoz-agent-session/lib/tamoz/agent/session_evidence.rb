# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    # Finds committed intents and turns effect outcomes into bounded evidence.
    # :reek:ControlParameter :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyMethods :reek:TooManyStatements :reek:UtilityFunction
    # Evidence helpers encode the durable observation and bounded-repair protocol.
    class SessionEvidence
      # Immutable details for a rejected or failed tool effect.
      ToolFailure = Data.define(:step, :tool, :error_class, :reason, :effect_receipt)
      MODEL_REFUSALS = { 401 => 'model_key_refused', 403 => 'model_key_refused', 402 => 'model_out_of_credit',
                         429 => 'model_rate_limited' }.freeze

      def initialize(configuration:)
        @configuration = configuration
      end

      def find_intent(state, accepted, step)
        intent = state.fetch(:effect_intents).reverse.find do |record|
          record.fetch('plan_id') == accepted.fetch('plan_id') &&
            record.fetch('step_id') == step.fetch('id')
        end
        raise ToolError, "no committed effect intent for step #{step.fetch('id')}" unless intent

        intent
      end

      def observation_payload(record)
        payload = {
          'phase' => record.fetch('phase'),
          'repair_attempt' => record.fetch('repair_attempt'),
          'step_id' => record.fetch('step_id'),
          'tool' => record['tool'],
          'output' => record.fetch('output'),
          'effect_key' => record['effect_key'],
          'provenance' => record['provenance'],
          'source_id' => record['source_id'],
          'truncated' => record['truncated'],
          'output_bytes' => record['output_bytes'],
          'result_class' => record['result_class'],
          'decision_digest' => record['decision_digest'],
          'evidence_ref' => record['evidence_ref']
        }
        payload['check'] = record.fetch('check') if record.key?('check')
        payload['failure'] = record.fetch('failure') if record.key?('failure')
        payload
      end

      def observation_bytes(state)
        state.fetch(:observations).sum { |record| record.fetch('output').bytesize }
      end

      def tool_failure_update(state, failure:)
        phase = state.fetch(:phase)
        failure_record = failure_record(failure)
        update = {
          step_cursor: state.fetch(:step_cursor) + 1,
          next_node: 'evaluate',
          observations: [failure_observation(state, phase, failure, failure_record)]
        }
        update[:effect_receipts] = [failure.effect_receipt] if failure.effect_receipt
        update
      end

      def tool_failure_output(tool, reason)
        <<~TEXT.chomp
          Tool #{tool} was rejected: #{reason}
          The workspace was not changed. Re-read the target with read_file and use its
          exact current bytes and digest before proposing a different action.
        TEXT
      end

      def tool_failure_signature(tool:, reason:, arguments:)
        Digest::SHA256.hexdigest(
          JSON.generate(
            'kind' => 'tool_error',
            'tool' => String(tool),
            'reason' => String(reason),
            'arguments_digest' => SessionRecords.digest(
              Tamoz::Agent::Deliberation.canonical(arguments)
            )
          )
        )
      end

      def repairable_outcome?(outcome)
        error = outcome.error
        error.is_a?(Hash) && error['repairable'] == true
      end

      def tool_error_class(outcome)
        error = outcome.error
        return 'Tamoz::Agent::ToolError' unless error.is_a?(Hash)

        String(error['class'] || 'Tamoz::Agent::ToolError')
      end

      def current_pass_tool_failure(state)
        phase = state.fetch(:phase)
        return nil unless %w[action repair].include?(phase)

        attempt = state.fetch(:repair_attempt)
        record = state.fetch(:observations).reverse.find do |entry|
          entry.key?('failure') &&
            entry.fetch('phase') == phase &&
            entry.fetch('repair_attempt') == attempt
        end
        record&.fetch('failure')
      end

      def current_pass_check(state)
        phase = state.fetch(:phase)
        attempt = state.fetch(:repair_attempt)
        record = state.fetch(:observations).reverse.find do |entry|
          entry.key?('check') &&
            entry.fetch('phase') == phase &&
            entry.fetch('repair_attempt') == attempt
        end
        record&.fetch('check')
      end

      def failed_check(state, check)
        bounded_repair(state, check.fetch('failure_signature'), repeated_reason: 'repeated_failure')
      end

      def bounded_repair(state, signature, repeated_reason:)
        repair_attempt = state.fetch(:repair_attempt)
        if state.fetch(:seen_failure_signatures).include?(signature)
          return { next_node: 'verify', terminal_reason: repeated_reason }
        end
        if repair_attempt >= @configuration.max_repair_attempts
          return {
            next_node: 'verify',
            terminal_reason: 'repair_attempts_exhausted',
            seen_failure_signatures: [signature]
          }
        end

        {
          next_node: 'deliberate',
          phase: 'repair',
          repair_attempt: repair_attempt + 1,
          step_cursor: 0,
          seen_failure_signatures: [signature]
        }
      end

      def last_semantic_review(state, accepted)
        record = state.fetch(:plan_reviews).reverse.find do |entry|
          entry.fetch('plan_id') == accepted.fetch('plan_id') &&
            entry.fetch('layer') == 'semantic'
        end
        return {} unless record

        {
          'decision' => record.fetch('decision'),
          'issues' => record.fetch('issues'),
          'rationale' => record.fetch('rationale', '')
        }
      end

      def blocked_update(outcome, reason, step_id: nil, operation: nil)
        refusal = model_refusal(outcome)
        return { next_node: 'terminal', terminal_reason: refusal } if refusal

        {
          next_node: 'terminal',
          terminal_reason: 'effect_unknown',
          blocked: SessionRecords.build(
            'blocked',
            reason:,
            effect_key: outcome.effect_key,
            operation: String(operation || 'model.generate'),
            step_id:,
            actions: [
              'inspect the operation and its target',
              'record the true outcome with Session#resolve_effect',
              'then continue the session'
            ]
          )
        }
      end

      def tool_error_message(outcome)
        error = outcome.error
        return 'tool effect failed' unless error.is_a?(Hash)

        String(error['message'] || 'tool effect failed')
      end

      private

      # A provider that answered with an error refused the call; its outcome is known, not unknown.
      def model_refusal(outcome)
        error = outcome.error
        return nil unless outcome.status == :failed && error.is_a?(Hash) && error['class'] == ModelCallError.name

        status = error['status'].to_i
        return nil if status.zero?

        MODEL_REFUSALS.fetch(status) { status >= 500 ? 'model_provider_down' : 'model_refused' }
      end

      def failure_record(failure)
        {
          'kind' => 'tool_error',
          'tool' => String(failure.tool),
          'error_class' => String(failure.error_class),
          'reason' => String(failure.reason),
          'failure_signature' => tool_failure_signature(
            tool: failure.tool,
            reason: failure.reason,
            arguments: failure.step.fetch('arguments')
          )
        }
      end

      def failure_observation(state, phase, failure, failure_record)
        SessionRecords.build(
          'observation',
          phase:,
          repair_attempt: state.fetch(:repair_attempt),
          step_id: failure.step.fetch('id'),
          tool: String(failure.tool),
          output: tool_failure_output(failure.tool, failure.reason),
          failure: failure_record
        )
      end
    end
  end
end
