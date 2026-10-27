# frozen_string_literal: true

require 'tamoz/stream/episode_worker'

# Drafts a rule-proposal eval case through the worker's DraftPlaybookRule, as Agentic Stream calls it.
module RuleProposalDrafter
  V1 = Agenticstream::Runtime::V1
  BUDGET = V1::DraftBudget.new(wall_time: Google::Protobuf::Duration.new(seconds: 60), model_calls: 6,
                               input_tokens: 30_000, output_tokens: 5_000)

  module_function

  def through(worker, tenant:)
    lambda do |request|
      answer(worker.draft_playbook_rule(wire_request(request, tenant:), nil).last)
    end
  end

  def wire_request(request, tenant:)
    V1::DraftRequest.new(
      protocol_version: '1.0', draft_id: request.fetch('draft_id'), tenant_id: tenant,
      key: V1::DraftKey.new(**request.fetch('key').transform_keys(&:to_sym)),
      cases: request.fetch('cases').map do |entry|
        V1::DraftCase.new(
          episode_id: entry.fetch('episode_id'), diagnosis_code: entry.fetch('diagnosis_code'),
          intent: entry.fetch('intent'), preset: entry.fetch('preset'), verdict: entry.fetch('verdict'),
          features_json: Tamoz::Core.jcs(entry.fetch('features')), summary: entry.fetch('summary')
        )
      end,
      allowed_features: request.fetch('allowed_features'), budget: BUDGET
    )
  end

  def answer(event)
    case event.event
    when :proposal
      proposal = event.proposal
      { 'proposal' => { 'when' => proposal.when, 'cited_episode_ids' => proposal.cited_episode_ids.to_a,
                        'rationale' => proposal.rationale } }
    when :no_proposal then { 'no_proposal' => { 'reason' => event.no_proposal.reason } }
    else { 'error' => event.diagnostic.code }
    end
  end
end
