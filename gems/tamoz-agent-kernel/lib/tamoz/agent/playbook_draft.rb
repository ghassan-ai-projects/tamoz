# frozen_string_literal: true

require 'tamoz/agent/errors'
require 'tamoz/agent/strict_document'
require 'tamoz/agent/feature_condition'

module Tamoz
  module Agent
    # The strict parser for a drafted playbook rule; the key comes from the request, never the model.
    module PlaybookDraft
      extend StrictDocument

      PROTOCOL = 'tamoz.playbook-draft/v1'
      ERROR_PREFIX = 'playbook_draft'
      MAX_BYTES = 16 * 1024
      MAX_CASES = 20
      MAX_ID_BYTES = 256
      MAX_RATIONALE_BYTES = 2048
      NO_PROPOSAL_REASONS = %w[
        contradicting_cases too_few_cases self_resolving mixed_keys insufficient_evidence
      ].freeze

      Proposal = Data.define(:when, :cited_episode_ids, :rationale)
      NoProposal = Data.define(:reason)

      class << self
        # cases: {episode_id => features at decision time}.
        def parse(bytes, cases:, allowed_features:)
          refuse 'not_string' unless bytes.is_a?(String)
          reject_oversize(bytes.bytesize, 'document', MAX_BYTES)
          reject_bad_utf8(bytes)
          root = strict_parse(bytes)
          refuse 'not_object' unless root.is_a?(Hash)
          reject_unknown_keys(root, %w[protocol proposal no_proposal], 'top_level')
          refuse "protocol: #{root['protocol'].inspect}" unless root['protocol'] == PROTOCOL
          refuse 'exactly_one_answer' unless root.key?('proposal') ^ root.key?('no_proposal')

          if root.key?('proposal')
            parse_proposal(root['proposal'], cases, allowed_features)
          else
            parse_no_proposal(root['no_proposal'])
          end
        end

        private

        def parse_proposal(proposal, cases, allowed_features)
          refuse 'proposal_not_object' unless proposal.is_a?(Hash)
          reject_unknown_keys(proposal, %w[when cited_episode_ids rationale], 'proposal')
          condition = parse_condition(fetch_bounded_string(proposal, 'when', FeatureCondition::MAX_BYTES),
                                      allowed_features)
          cited = parse_cited(proposal, cases)
          cited.each do |id|
            reason = condition.failure(cases.fetch(id))
            refuse "when_fails_case: #{id}: #{reason}" if reason
          end
          rationale = fetch_bounded_string(proposal, 'rationale', MAX_RATIONALE_BYTES)
          refuse 'rationale_blank' if rationale.strip.empty?

          Proposal.new(when: proposal['when'], cited_episode_ids: cited, rationale:)
        end

        def parse_condition(text, allowed_features)
          FeatureCondition.parse(text, allowed: allowed_features)
        rescue FeatureCondition::Invalid => e
          refuse "when_invalid: #{e.message}"
        end

        def parse_cited(proposal, cases)
          cited = fetch_array(proposal, 'cited_episode_ids', MAX_CASES)
          refuse 'cited_episode_ids_empty' if cited.empty?
          cited.each do |id|
            refuse 'cited_episode_id_not_string' unless id.is_a?(String)
            reject_oversize(id.bytesize, 'cited_episode_id', MAX_ID_BYTES)
            refuse "cited_unknown_case: #{id}" unless cases.key?(id)
          end
          refuse 'cited_episode_ids_duplicate' unless cited.uniq.length == cited.length

          cited
        end

        def parse_no_proposal(answer)
          refuse 'no_proposal_not_object' unless answer.is_a?(Hash)
          reject_unknown_keys(answer, %w[reason], 'no_proposal')
          reason = fetch_bounded_string(answer, 'reason', MAX_ID_BYTES)
          refuse "no_proposal_reason: #{reason}" unless NO_PROPOSAL_REASONS.include?(reason)

          NoProposal.new(reason:)
        end
      end
    end
  end
end
