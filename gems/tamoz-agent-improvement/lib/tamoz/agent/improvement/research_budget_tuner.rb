# frozen_string_literal: true

module Tamoz
  module Agent
    module Improvement
      # Proposes fewer waves for a depth whose development runs mostly stopped on saturation. The proposal is a
      # `CandidateLifecycle` candidate; `Tamoz::Research.budgets(override:)` refuses any number it would raise.
      # :reek:FeatureEnvy :reek:TooManyStatements -- the candidate carries the proposal's identity; one grouping chain.
      class ResearchBudgetTuner
        SATURATION_SHARE = 0.6

        def self.fewer_waves(runs)
          saturated = runs.count { |record| record.fetch('stop_reason') == 'saturation' }
          waves = runs.map { |record| record.fetch('waves') }.max
          waves - 1 if saturated.fdiv(runs.length) >= SATURATION_SHARE && waves > 1
        end

        def initialize(records:, holdout_ids:)
          @records = Array(records)
          held_out = @records.map { |record| record.fetch('run_id') } & Array(holdout_ids)
          raise ArgumentError, "held-out runs are not tuning inputs: #{held_out.join(', ')}" unless held_out.empty?
        end

        def candidate_content
          waves = @records.group_by { |record| record.fetch('depth') }
                          .transform_values { |runs| self.class.fewer_waves(runs) }.compact
          waves.empty? ? {} : { 'depths' => waves.transform_values { |count| { 'waves' => count } } }
        end

        def candidate_digest = Tamoz::Core.digest("tamoz.research.budget_candidate.v1\n", candidate_content)

        # What a lifecycle's resolver returns for `proposal`.
        def candidate(proposal:)
          { 'profile_id' => proposal.profile_id, 'scope' => proposal.scope, 'digest' => proposal.to_digest,
            'content' => candidate_content }
        end

        def budgets = Tamoz::Research.budgets(override: candidate_content)
      end
    end
  end
end
