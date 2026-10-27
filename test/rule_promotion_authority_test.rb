# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/stream/draft_runner'
require 'support/local_model_endpoint'
require 'support/episode_composition'

# Invariant 34: Tamoz drafts a playbook rule; it never sets a rule's mode or writes Agentic Stream state.
class RulePromotionAuthorityTest < Minitest::Test
  V1 = Agenticstream::Runtime::V1
  LIBRARIES = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].reject { |path| path.include?('/gen/') }

  def test_the_wire_reply_has_no_field_for_mode_activation_envelope_or_approval
    proposal = V1::PlaybookProposal.descriptor.map(&:name)

    assert_equal %w[diagnosis_code intent preset when cited_episode_ids rationale], proposal
    assert_equal %w[diagnostic proposal no_proposal usage], V1::DraftEvent.descriptor.map(&:name)
  end

  def test_tamoz_serves_the_episode_worker_and_dials_only_the_read_only_evidence_tools
    assert_equal %i[Handshake Execute DraftPlaybookRule], V1::EpisodeWorker::Service.rpc_descs.keys
    stubs = LIBRARIES.flat_map { |path| File.read(path).scan(/V1::(\w+)::Stub/).flatten }.uniq

    assert_equal ['EvidenceTools'], stubs
  end

  def test_only_the_reply_builder_builds_a_proposal_and_nothing_builds_a_rule_or_an_approval
    builders = LIBRARIES.select { |path| File.read(path).include?('PlaybookProposal') }
    writers = LIBRARIES.select { |path| File.read(path).match?(/DraftRule\.new|rprop_/) }

    assert_equal [File.join(ROOT, 'gems/tamoz-stream/lib/tamoz/stream/draft_reply.rb')], builders
    assert_empty writers
  end

  def test_a_model_that_sets_a_mode_gets_no_proposal_even_after_repair
    smuggled = Tamoz::Core.jcs({ 'protocol' => Tamoz::Agent::PlaybookDraft::PROTOCOL,
                                 'proposal' => { 'when' => 'features.a > 1.0', 'cited_episode_ids' => ['ep-1'],
                                                 'rationale' => 'r', 'mode' => 'active' } })
    Dir.mktmpdir('tamoz-authority') do |dir|
      endpoint = LocalModelEndpoint.new(mode: :fixture, responses: [smuggled],
                                        log_path: File.join(dir, 'endpoint.log')).start
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      runner = Tamoz::Stream::DraftRunner.new(durable_runner: composition.fetch(:app).durable_runner, tenant: 'acme',
                                              model_policy: 'fast')

      event = runner.run(request).first

      assert_equal :diagnostic, event.event
      assert_equal 2, endpoint.observed.length, 'the refusal went through the one repair'
    ensure
      endpoint&.stop
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end

  def request
    V1::DraftRequest.new(
      protocol_version: '1.0', draft_id: 'draft-authority', tenant_id: 'acme',
      key: V1::DraftKey.new(diagnosis_code: 'code_a', intent: 'act', preset: 'p1'),
      cases: [V1::DraftCase.new(episode_id: 'ep-1', verdict: 'verified', features_json: Tamoz::Core.jcs({ 'a' => 2.0 }))],
      allowed_features: %w[a]
    )
  end
end
