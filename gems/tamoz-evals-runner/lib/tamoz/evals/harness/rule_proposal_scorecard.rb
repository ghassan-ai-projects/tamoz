# frozen_string_literal: true

require 'digest'
require 'tamoz/agent/feature_condition'

module Tamoz
  module Evals
    module Harness
      # Grades playbook-rule drafts against preregistered cases: the right rule, or none.
      class RuleProposalScorecard
        REPORT_DOMAIN = 'eval.rule-proposal-scorecard'
        REPORT_TYPE = 'rule_proposal_scorecard'
        Condition = Tamoz::Agent::FeatureCondition

        def self.control_drafters(cases)
          oracle = cases.to_h { |entry| [entry.fetch('case_id'), entry.fetch('oracle')] }
          {
            'null' => ->(_request) {},
            'oracle' => ->(request) { oracle.fetch(request.fetch('draft_id')) },
            'adversary' => ->(request) { proposal('true', request.fetch('cases')) },
            'overfit' => ->(request) { proposal(memorised(request.fetch('cases')), request.fetch('cases')) },
            'decline' => ->(_request) { { 'no_proposal' => { 'reason' => 'insufficient_evidence' } } }
          }
        end

        def self.proposal(condition, cases)
          { 'proposal' => { 'when' => condition, 'cited_episode_ids' => cases.map { |entry| entry.fetch('episode_id') },
                            'rationale' => 'control' } }
        end

        # Matches exactly the values it was shown on the feature that varies most, and nothing else.
        def self.memorised(cases)
          numeric = cases.first.fetch('features').select { |_key, value| value.is_a?(Numeric) }.keys
          name = numeric.max_by do |key|
            cases.map { |entry| entry.dig('features', key) }.uniq.length
          end
          cases.map { |entry| "features.#{name} == #{Float(entry.dig('features', name))}" }.join(' || ')
        end

        def initialize(cases:, allowed_features:, drafter:, subject:)
          @cases = cases
          @allowed_features = allowed_features
          @drafter = drafter
          @subject = subject
        end

        def run
          reports = @cases.map { |entry| grade(entry, answer_for(entry)) }
          document = report(reports)
          document['content_digest'] = CanonicalJSON.content_digest(document, domain: REPORT_DOMAIN)
          ScorecardReport.new(document:)
        end

        private

        def request_for(entry)
          entry.fetch('request').merge('draft_id' => entry.fetch('case_id'), 'allowed_features' => @allowed_features)
        end

        def answer_for(entry)
          @drafter.call(request_for(entry))
        rescue StandardError => e
          { 'error' => e.class.name }
        end

        def grade(entry, answer)
          kind = answer_kind(answer)
          failure = case kind
                    when 'no_proposal' then decline_failure(entry, answer)
                    when 'proposal' then if entry.fetch('abstain_expected')
                                           'proposed where no rule was expected'
                                         else
                                           proposal_failure(
                                             entry, answer
                                           )
                                         end
                    else "no answer (#{kind})"
                    end
          {
            'case_id' => entry.fetch('case_id'), 'family' => entry.fetch('family'),
            'abstain_expected' => entry.fetch('abstain_expected'), 'answer' => kind,
            'passed' => failure.nil?, 'failure' => failure
          }.compact
        end

        def answer_kind(answer)
          return 'none' unless answer.is_a?(Hash)

          (%w[proposal no_proposal error] & answer.keys).first || 'none'
        end

        def decline_failure(entry, answer)
          gold = entry.fetch('gold')
          return 'declined where a rule was expected' unless entry.fetch('abstain_expected') || gold['allow_decline']

          reason = answer.dig('no_proposal', 'reason')
          "declined for #{reason}" unless gold.fetch('reasons', [reason]).include?(reason)
        end

        def proposal_failure(entry, answer)
          proposal = answer.fetch('proposal')
          condition = Condition.parse(proposal.fetch('when'), allowed: @allowed_features)
          cited_failure(entry, Array(proposal.fetch('cited_episode_ids'))) || condition_failure(entry, condition)
        rescue Condition::Invalid => e
          "invalid condition: #{e.message}"
        rescue KeyError, TypeError, NoMethodError
          'malformed proposal'
        end

        def cited_failure(entry, cited)
          gold = entry.fetch('gold')
          trusted = trusted_cases(entry).map { |item| item.fetch('episode_id') }
          return 'cites a case that is not a trusted verified case' unless (cited - trusted).empty?

          return unless cited.uniq.length < gold.fetch('min_cited')

          "cites #{cited.uniq.length} of at least #{gold.fetch('min_cited')}"
        end

        def condition_failure(entry, condition)
          gold = entry.fetch('gold')
          missed = trusted_cases(entry).find { |item| !condition.holds?(item.fetch('features')) }
          return "does not hold for #{missed.fetch('episode_id')}" if missed
          return 'does not hold for an unseen case of this key' unless gold.fetch('must_hold').all? do |features|
            condition.holds?(features)
          end

          'also matches a look-alike it must reject' if gold.fetch('must_reject').any? do |features|
            condition.holds?(features)
          end
        end

        def trusted_cases(entry)
          never = entry.fetch('gold').fetch('never_cite', [])
          entry.fetch('request').fetch('cases').select do |item|
            item.fetch('verdict') == 'verified' && !never.include?(item.fetch('episode_id'))
          end
        end

        def report(cases)
          proposals = cases.reject { |entry| entry.fetch('abstain_expected') }
          abstentions = cases.select { |entry| entry.fetch('abstain_expected') }
          {
            'report_type' => REPORT_TYPE, 'format_version' => 1, 'content_digest' => 'pending',
            'subject' => @subject,
            'corpus' => { 'case_count' => cases.length, 'digest' => corpus_digest },
            'cases' => cases,
            'aggregate' => {
              'passed' => cases.count { |entry| entry.fetch('passed') },
              'proposals_expected' => proposals.length,
              'proposals_passed' => proposals.count { |entry| entry.fetch('passed') },
              'abstentions_expected' => abstentions.length,
              'abstentions_passed' => abstentions.count { |entry| entry.fetch('passed') }
            },
            'decision' => !cases.empty? && cases.all? { |entry| entry.fetch('passed') } ? 'pass' : 'fail'
          }
        end

        def corpus_digest = "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(@cases))}"
      end
    end
  end
end
