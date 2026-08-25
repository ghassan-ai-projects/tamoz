# frozen_string_literal: true

module Tamoz
  module Agent
    # Commits plan-review decisions into durable graph-node updates.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:LongParameterList :reek:UtilityFunction
    # These branches own the exact accepted, clarification, and rejection updates.
    class SessionPlanOutcomes
      # Inputs needed to accept a reviewed plan.
      Acceptance = Data.define(
        :plan,
        :plan_id,
        :plan_digest,
        :plan_hash,
        :phase,
        :plans,
        :reviews,
        :ambiguity
      )

      # Inputs needed to resolve a reviewer request for operator input.
      Clarification = Data.define(
        :context,
        :plan_id,
        :plan_digest,
        :review,
        :phase,
        :repair_attempt,
        :plans,
        :reviews,
        :ambiguity
      )

      # Inputs needed to finish a failed deliberation pass.
      Rejection = Data.define(:plans, :reviews, :ambiguity, :phase, :repair_attempt)

      def initialize(configuration:)
        @configuration = configuration
      end

      def accept_plan(state, acceptance:)
        details = acceptance
        base = acceptance_updates(state, details)
        return repeated_action_update(state, details, base) if action_phase?(details.phase)

        base.merge(
          accepted_plan: accepted_plan(details),
          step_cursor: 0,
          next_node: 'step_gate'
        )
      end

      def plan_rejected(state, rejection:)
        details = rejection
        if details.phase == :repair && details.repair_attempt.positive?
          return {
            plan_versions: new_records(state, :plan_versions, details.plans, 'plan_id'),
            plan_reviews: new_records(state, :plan_reviews, details.reviews, 'review_id'),
            provider_ambiguity: details.ambiguity,
            next_node: 'verify',
            terminal_reason: 'repair_plan_rejected'
          }
        end

        raise PlanRejectedError, plan_rejected_message(details.reviews)
      end

      def plan_rejected_message(reviews)
        prefix = "no plan passed review after #{@configuration.max_plan_attempts} attempts"
        last = reviews.last
        unless last && last.fetch('layer') == 'structural' && last.fetch('decision') == 'revise'
          return "#{prefix}: the plan did not pass review; the last feedback is not discloseable"
        end

        "#{prefix}: #{last.fetch('issues').first(3).join('; ')}"
      end

      def clarify_update(state, clarification:)
        details = clarification
        clarify_step_id, answer = clarification_input(state, details)

        {
          plan_versions: new_records(state, :plan_versions, details.plans, 'plan_id'),
          plan_reviews: new_records(state, :plan_reviews, details.reviews, 'review_id'),
          provider_ambiguity: details.ambiguity,
          observations: [
            SessionRecords.build(
              'observation',
              phase: details.phase.to_s,
              repair_attempt: details.repair_attempt,
              step_id: clarify_step_id,
              output: answer.strip,
              tool: 'clarify'
            )
          ],
          next_node: 'deliberate'
        }
      end

      private

      def action_phase?(phase)
        %i[action repair].include?(phase)
      end

      def acceptance_updates(state, details)
        {
          plan_versions: new_records(state, :plan_versions, details.plans, 'plan_id'),
          plan_reviews: new_records(state, :plan_reviews, details.reviews, 'review_id'),
          provider_ambiguity: details.ambiguity
        }
      end

      def repeated_action_update(state, details, base)
        signature = Tamoz::Agent::Deliberation.action_signature(details.plan)
        return base.merge(next_node: 'verify', terminal_reason: 'repeated_action') if
          state.fetch(:seen_action_signatures).include?(signature)

        base.merge(seen_action_signatures: [signature]).merge(
          accepted_plan: accepted_plan(details),
          step_cursor: 0,
          next_node: 'step_gate'
        )
      end

      def accepted_plan(details)
        SessionRecords.build(
          'accepted_plan',
          plan_id: details.plan_id,
          plan_digest: details.plan_digest,
          phase: details.phase.to_s,
          plan: details.plan_hash,
          accepted_at_ms: 0
        )
      end

      def clarification_input(state, details)
        answer = Tamoz.interrupt(clarification_descriptor(state, details), details.context)
        clarify_step_id = "clarify.#{details.plan_id}"
        validate_clarification(state, details, clarify_step_id, answer)
        [clarify_step_id, answer]
      end

      def clarification_descriptor(state, details)
        {
          'kind' => 'clarify',
          'session_id' => state.fetch(:session).fetch('session_id'),
          'plan_id' => details.plan_id,
          'plan_digest' => details.plan_digest,
          'question' => details.review.fetch('issues').join("\n"),
          'context' => {
            'phase' => details.phase.to_s,
            'repair_attempt' => details.repair_attempt
          }
        }
      end

      def validate_clarification(state, details, clarify_step_id, answer)
        if state.fetch(:observations).any? { |record| record.fetch('step_id') == clarify_step_id }
          raise Tamoz::InvalidUpdateError,
                "clarify interrupt for #{details.plan_id} has already been answered"
        end
        return if answer.is_a?(String) && !answer.strip.empty?

        raise Tamoz::InvalidUpdateError, 'clarify answer must be a non-empty string'
      end

      def new_records(state, channel, records, id_key)
        existing = state.fetch(channel).map { |record| record.fetch(id_key) }
        records.reject { |record| existing.include?(record.fetch(id_key)) }
      end
    end
  end
end
