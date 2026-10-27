# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/stream/draft_runner'
require 'tamoz/stream/worker_server'
require 'support/local_model_endpoint'
require 'support/episode_composition'

class StreamDraftPlaybookRuleTest < Minitest::Test
  V1 = Agenticstream::Runtime::V1
  Draft = Tamoz::Agent::PlaybookDraft
  CASES = { 'ep-1' => { 'a' => 2.0, 'b' => 1.0 }, 'ep-2' => { 'a' => 3.0, 'b' => 1.0 },
            'ep-3' => { 'a' => 2.5, 'b' => 1.0 } }.freeze

  def proposal_bytes(when_text, cited = CASES.keys)
    Tamoz::Core.jcs({ 'protocol' => Draft::PROTOCOL,
                      'proposal' => { 'when' => when_text, 'cited_episode_ids' => cited, 'rationale' => 'a rises' } })
  end

  def no_proposal_bytes(reason)
    Tamoz::Core.jcs({ 'protocol' => Draft::PROTOCOL, 'no_proposal' => { 'reason' => reason } })
  end

  def request(draft_id: 'draft-1', cases: CASES, key_code: 'code_a', tenant: 'acme', summary: 'settled after service')
    V1::DraftRequest.new(
      protocol_version: '1.0', draft_id:, tenant_id: tenant,
      key: V1::DraftKey.new(diagnosis_code: key_code, kind_digest: 'sha256:k', intent: 'act', preset: 'p1'),
      cases: cases.map do |id, features|
        V1::DraftCase.new(episode_id: id, diagnosis_code: key_code, intent: 'act', preset: 'p1', verdict: 'verified',
                          features_json: Tamoz::Core.jcs(features), summary:)
      end,
      allowed_features: %w[a b],
      budget: V1::DraftBudget.new(wall_time: Google::Protobuf::Duration.new(seconds: 60), model_calls: 3)
    )
  end

  def with_worker(*responses)
    Dir.mktmpdir('tamoz-draft') do |dir|
      endpoint = LocalModelEndpoint.new(mode: :fixture, responses:, log_path: File.join(dir, 'endpoint.log')).start
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      worker = Tamoz::Stream::EpisodeWorker.new(worker_version: 'test').bind_draft_runner(
        Tamoz::Stream::DraftRunner.new(durable_runner: composition.fetch(:app).durable_runner, tenant: 'acme',
                                       model_policy: 'fast')
      )
      yield worker, endpoint
    ensure
      endpoint&.stop
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end

  def draft(worker, wire = request) = worker.draft_playbook_rule(wire, nil)

  def test_the_handshake_announces_drafting_only_when_a_draft_runner_is_bound
    handshake = V1::HandshakeRequest.new(protocol_version: '1.0', contract_version: '1.0', worker_id: 'w',
                                         runtime_instance_id: 'r', non_interactive: true)

    with_worker(no_proposal_bytes('too_few_cases')) do |worker, _endpoint|
      assert_includes worker.handshake(handshake, nil).supported_features, 'draft_playbook_rule'
    end
    assert_empty Tamoz::Stream::EpisodeWorker.new(worker_version: 'test').handshake(handshake, nil).supported_features
  end

  def test_consistent_cases_give_a_proposal_for_the_requests_key
    with_worker(proposal_bytes('features.a / features.b > 1.5')) do |worker, _endpoint|
      events = draft(worker)

      assert_equal 1, events.length
      assert_equal V1::PlaybookProposal.new(diagnosis_code: 'code_a', intent: 'act', preset: 'p1',
                                            when: 'features.a / features.b > 1.5', cited_episode_ids: CASES.keys,
                                            rationale: 'a rises'), events.first.proposal
    end
  end

  def test_contradicting_cases_give_no_proposal
    with_worker(no_proposal_bytes('contradicting_cases')) do |worker, _endpoint|
      events = draft(worker)

      assert_equal 'contradicting_cases', events.first.no_proposal.reason
    end
  end

  def test_a_condition_failing_a_cited_case_is_repaired_by_a_second_journaled_call
    with_worker(proposal_bytes('features.a > 2.2'), proposal_bytes('features.a > 1.5')) do |worker, endpoint|
      events = draft(worker)

      assert_equal 'features.a > 1.5', events.first.proposal.when
      assert_equal 2, endpoint.observed.length
    end
  end

  def test_a_redelivered_draft_returns_the_recorded_answer_without_a_new_model_call
    with_worker(proposal_bytes('features.a > 1.5'), no_proposal_bytes('too_few_cases')) do |worker, endpoint|
      first = draft(worker)
      again = draft(worker)

      assert_equal first, again
      assert_equal 1, endpoint.observed.length
    end
  end

  def test_an_oversized_request_is_refused_before_any_model_call
    with_worker(no_proposal_bytes('too_few_cases')) do |worker, endpoint|
      many = 21.times.to_h { |index| ["ep-#{index}", { 'a' => 1.0 }] }
      assert_raises(GRPC::InvalidArgument) { draft(worker, request(cases: many)) }

      large = draft(worker, request(draft_id: 'draft-large', summary: 'x' * 5000))

      assert_equal 'graph_step_failed', large.first.diagnostic.code
      assert_empty endpoint.observed
    end
  end

  def test_a_draft_for_another_tenant_or_the_unknown_code_is_refused
    with_worker(no_proposal_bytes('too_few_cases')) do |worker, endpoint|
      assert_raises(GRPC::InvalidArgument) { draft(worker, request(tenant: 'other')) }
      assert_raises(GRPC::InvalidArgument) { draft(worker, request(key_code: 'unknown')) }
      assert_empty endpoint.observed
    end
  end

  def test_the_draft_streams_over_grpc
    with_worker(no_proposal_bytes('self_resolving')) do |worker, _endpoint|
      server = Tamoz::Stream::WorkerServer.new(worker:, port: 0)
      port, = server.start
      stub = V1::EpisodeWorker::Stub.new("127.0.0.1:#{port}", :this_channel_is_insecure)

      assert_equal(['self_resolving'], stub.draft_playbook_rule(request).map { |event| event.no_proposal.reason })
    ensure
      server&.stop
    end
  end

  def test_two_bad_answers_end_typed_with_the_usage_of_both_calls
    with_worker(proposal_bytes('features.a > 2.2'), proposal_bytes('features.a > 2.9')) do |worker, endpoint|
      event = draft(worker).first

      assert_equal 'graph_step_failed', event.diagnostic.code
      assert_equal 2, endpoint.observed.length
      assert_equal 2 * 42, event.usage.input_tokens, 'both journaled calls are counted'
    end
  end

  def test_an_id_the_store_cannot_hold_or_a_repeated_case_is_refused_before_any_model_call
    with_worker(no_proposal_bytes('too_few_cases')) do |worker, endpoint|
      assert_raises(GRPC::InvalidArgument) { draft(worker, request(draft_id: 'd' * 121)) }
      assert_equal 'too_few_cases', draft(worker, request(draft_id: 'd' * 120)).first.no_proposal.reason
      repeated = request
      repeated.cases.last.episode_id = 'ep-1'
      assert_raises(GRPC::InvalidArgument) { draft(worker, repeated) }
      assert_equal 1, endpoint.observed.length
    end
  end

  def test_a_fixture_provider_never_drafts
    worker = Tamoz::Stream::EpisodeWorker.new(worker_version: 'test', provider_mode: :fixture)
                                         .bind_draft_runner(Object.new)
    assert_raises(GRPC::FailedPrecondition) { worker.draft_playbook_rule(request, nil) }
  end

  def test_a_worker_without_a_draft_runner_does_not_draft
    assert_raises(GRPC::Unimplemented) do
      Tamoz::Stream::EpisodeWorker.new(worker_version: 'test').draft_playbook_rule(request, nil)
    end
  end
end
