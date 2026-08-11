# frozen_string_literal: true

module Tamoz
  module Agent
    # User-facing progress is derived only from committed session evidence.
    # Model answers and intended plan steps never increment these counters.
    module TerminalProgress
      IDENTIFIER = %r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}\z}
      STOP_ACTIONS = {
        'repair_attempts_exhausted' => 'review the committed evidence and resume with a narrower next step',
        'repeated_action' => 'resume with a different next step based on the committed evidence',
        'repeated_failure' => 'correct the failed check and resume',
        'repeated_tool_failure' => 'correct the tool input and resume',
        'effect_unknown' => 'resolve the unknown effect and resume',
        'approval_denied' => 'approve the required action or revise the request',
        'cancelled_by_user' => 'submit the remaining work again if it is still needed',
        'completed_without_check' => 'run the configured check before treating the result as verified',
        'direct_response' => 'request evidence-backed work when current state is needed'
      }.freeze

      module_function

      # rubocop:disable Metrics/AbcSize -- this method derives one bounded
      # projection from the durable receipt collection.
      def summarize(view)
        receipts = Array(view&.effect_receipts)
        successful = receipts.select { |receipt| receipt['status'] == 'succeeded' }
        step_ids = successful.filter_map { |receipt| receipt['step_id'] }.uniq
        steps = view&.accepted_plan&.dig('plan', 'steps')
        total = steps.is_a?(Array) ? steps.length : 0
        {
          'completed_steps' => [step_ids.length, total].min,
          'total_steps' => total,
          'verified_artifact_ids' => successful.filter_map { |receipt| safe_identifier(receipt['external_id']) }.uniq
        }
      end
      # rubocop:enable Metrics/AbcSize

      def progress_line(view)
        summary = summarize(view)
        completed = summary.fetch('completed_steps')
        total = summary.fetch('total_steps')
        if total.positive?
          "Committed progress: #{completed} of #{total} planned steps."
        elsif completed.positive?
          "Committed progress: #{completed} verified steps."
        else
          'Committed progress: no verified steps.'
        end
      end

      def artifact_line(view)
        identifiers = summarize(view).fetch('verified_artifact_ids')
        return nil if identifiers.empty?

        "Verified artifact identifiers: #{identifiers.join(', ')}."
      end

      def next_action(reason, budget: nil)
        return "raise the #{budget} budget and resume" if budget

        STOP_ACTIONS.fetch(reason, 'review the committed evidence and resume')
      end

      def safe_identifier(value)
        text = value.to_s
        text if IDENTIFIER.match?(text)
      end
      private_class_method :safe_identifier
    end
  end
end
