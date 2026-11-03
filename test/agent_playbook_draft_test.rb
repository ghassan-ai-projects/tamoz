# frozen_string_literal: true

require_relative 'test_helper'

class AgentPlaybookDraftTest < Minitest::Test
  Draft = Tamoz::Agent::PlaybookDraft
  ALLOWED = %w[a b].freeze
  CASES = { 'ep-1' => { 'a' => 2.0, 'b' => 1.0 }, 'ep-2' => { 'a' => 3.0, 'b' => 1.0 },
            'ep-3' => { 'a' => 0.5, 'b' => 1.0 } }.freeze

  def proposal(**overrides)
    {
      'protocol' => Draft::PROTOCOL,
      'proposal' => {
        'when' => 'features.a / features.b > 1.5', 'cited_episode_ids' => %w[ep-1 ep-2],
        'rationale' => 'a rises against b in every cited case'
      }.merge(overrides.transform_keys(&:to_s))
    }
  end

  def parse(document)
    Draft.parse(document.is_a?(String) ? document : JSON.generate(document),
                cases: CASES, allowed_features: ALLOWED)
  end

  def assert_refused(code, document)
    error = assert_raises(Tamoz::Agent::ProtocolError) { parse(document) }
    assert_includes error.message, "playbook_draft/#{code}"
  end

  def test_a_proposal_holding_for_every_cited_case_parses
    draft = parse(proposal)

    assert_equal Draft::Proposal.new(when: 'features.a / features.b > 1.5', cited_episode_ids: %w[ep-1 ep-2],
                                     rationale: 'a rises against b in every cited case'), draft
  end

  def test_a_no_proposal_carries_a_closed_reason
    assert_equal Draft::NoProposal.new(reason: 'contradicting_cases'),
                 parse({ 'protocol' => Draft::PROTOCOL, 'no_proposal' => { 'reason' => 'contradicting_cases' } })
    assert_refused 'no_proposal_reason: looks_fine',
                   { 'protocol' => Draft::PROTOCOL, 'no_proposal' => { 'reason' => 'looks_fine' } }
  end

  def test_authority_fields_cannot_be_expressed
    %w[mode active envelope approval intent preset diagnosis_code].each do |field|
      assert_refused "unknown_key: proposal.#{field}", proposal(field => 'x')
      assert_refused "unknown_key: top_level.#{field}", proposal.merge(field => 'x')
    end
  end

  def test_a_condition_failing_a_cited_case_is_refused
    assert_refused 'when_fails_case: ep-3: it evaluates to false', proposal(cited_episode_ids: %w[ep-1 ep-3])
  end

  def test_a_condition_outside_the_allowed_features_or_the_subset_is_refused
    assert_refused 'when_invalid: features.c is not an allowed feature', proposal(when: 'features.c > 1.0')
    assert_refused 'when_invalid: unexpected', proposal(when: 'has(features.a)')
  end

  def test_cited_cases_must_be_a_non_empty_unique_subset_of_the_request
    assert_refused 'cited_episode_ids_empty', proposal(cited_episode_ids: [])
    assert_refused 'cited_unknown_case: ep-9', proposal(cited_episode_ids: %w[ep-1 ep-9])
    assert_refused 'cited_episode_ids_duplicate', proposal(cited_episode_ids: %w[ep-1 ep-1])
    assert_refused 'cited_episode_id_not_string', proposal(cited_episode_ids: [1])
    assert_refused 'cited_episode_ids_too_many', proposal(cited_episode_ids: Array.new(21) { |i| "ep-#{i}" })
  end

  def test_the_envelope_of_the_document_is_strict
    assert_refused 'exactly_one_answer', proposal.merge('no_proposal' => { 'reason' => 'too_few_cases' })
    assert_refused 'exactly_one_answer', { 'protocol' => Draft::PROTOCOL }
    assert_refused 'protocol', proposal.merge('protocol' => 'tamoz.episode-diagnosis/v2')
    assert_refused 'rationale_blank', proposal(rationale: '  ')
    assert_refused 'duplicate_key', %({"protocol":"#{Draft::PROTOCOL}","protocol":"x"})
    assert_refused 'malformed_json', 'Here is my rule: {}'
    assert_refused 'document_too_large', ' ' * (Draft::MAX_BYTES + 1)
  end
end
