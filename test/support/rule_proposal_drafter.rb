# frozen_string_literal: true

require 'tmpdir'
require 'tamoz/stream/episode_worker'
require 'tamoz/stream/draft_runner'
require_relative 'episode_composition'
require_relative 'local_model_endpoint'

# Drafts a rule-proposal eval case through the worker's DraftPlaybookRule, as Agentic Stream calls it.
module RuleProposalDrafter
  V1 = Agenticstream::Runtime::V1
  BUDGET = V1::DraftBudget.new(wall_time: Google::Protobuf::Duration.new(seconds: 60), model_calls: 6,
                               input_tokens: 30_000, output_tokens: 5_000)

  module_function

  def worker(composition)
    Tamoz::Stream::EpisodeWorker.new(worker_version: 'test').bind_draft_runner(
      Tamoz::Stream::DraftRunner.new(durable_runner: composition.fetch(:app).durable_runner, tenant: 'acme',
                                     model_policy: 'fast')
    )
  end

  # Yields a drafting worker whose model answers each call with the next fixture response, and that endpoint.
  def with_fixture_worker(responses)
    Dir.mktmpdir('tamoz-draft') do |dir|
      endpoint = LocalModelEndpoint.new(mode: :fixture, responses:, log_path: File.join(dir, 'endpoint.log')).start
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      yield worker(composition), endpoint
    ensure
      endpoint&.stop
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end

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
