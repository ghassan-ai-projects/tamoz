# frozen_string_literal: true

module Tamoz
  module Agent
    module Improvement
      # Candidate-only profile/config handoff. The agent may construct and
      # validate this value, but promotion records only an operator-side,
      # next-boundary transition; it never activates authority.
      CandidateProposal = Data.define(
        :thread_id, :profile_id, :from_digest, :to_digest, :scope, :created_by
      ) do
        # rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/AbcSize, Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- one immutable candidate gate.
        SCOPES = %w[profile skill config].freeze

        def self.build(thread_id:, profile_id:, from_digest:, to_digest:, scope:, created_by:)
          values = {
            thread_id: String(thread_id), profile_id: String(profile_id),
            from_digest: String(from_digest), to_digest: String(to_digest),
            scope: String(scope), created_by: String(created_by)
          }
          raise ImprovementPolicyError, 'candidate proposal has an empty identity' if
            values.values.any?(&:empty?)
          raise ImprovementPolicyError, 'candidate proposal scope is not supported' unless
            SCOPES.include?(values.fetch(:scope))

          values.values_at(:from_digest, :to_digest).each do |digest|
            raise ImprovementPolicyError, 'candidate proposal digest is invalid' unless
              Tamoz::Core.valid_digest?(digest)
          end
          raise ImprovementPolicyError, 'candidate proposal is a no-op' if
            values.fetch(:from_digest) == values.fetch(:to_digest)

          new(**values).freeze
        end

        def promote!(registry:, candidate_resolver:, actor:, human_gate_evidence:)
          actor = String(actor)
          unless human_gate_evidence.to_s.start_with?(EvaluationReport::HUMAN_GATE_PREFIX) &&
                 human_gate_evidence.to_s.length > EvaluationReport::HUMAN_GATE_PREFIX.length
            raise UngatedActivationError, 'candidate promotion requires a human approval artifact'
          end
          raise SelfPromotionError, 'candidate creator cannot promote the candidate' if actor == created_by
          unless candidate_resolver.respond_to?(:call)
            raise ImprovementPolicyError, 'candidate promotion requires an operator-owned resolver'
          end

          resolved = candidate_resolver.call(to_digest)
          unless resolved.is_a?(Hash) && resolved['profile_id'] == profile_id &&
                 resolved['digest'] == to_digest && resolved['scope'] == scope
            raise EvaluatorTamperError, 'candidate artifact does not match the proposed digest and scope'
          end

          transition = registry.record(
            Profile::Transition.new(
              thread_id:, profile_id:, from_digest:, to_digest:,
              reason: "candidate_#{scope}_promotion"
            )
          )
          { 'transition' => transition, 'activated' => false, 'candidate_digest' => to_digest }.freeze
        end
        # rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/AbcSize, Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      end
    end
  end
end
