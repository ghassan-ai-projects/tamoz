# frozen_string_literal: true

require_relative 'test_helper'

# ADR-049 / PLAN_ADR049 Phase 1 — the evidence lattice and the v1 approval
# policy (trusted core, inert): closed total order, sanctioned minting only,
# and a policy whose input is provably ignored (INV-C lock).
# rubocop:disable Minitest/MultipleAssertions
class CommsAuthorityEvidenceTest < Minitest::Test
  Comms = Tamoz::Comms

  def test_lattice_is_closed_and_totally_ordered
    chat = Comms::AuthorityEvidence.chat_bound
    operator = Comms::AuthorityEvidence.filesystem_operator

    assert_operator chat, :<, operator
    assert_operator operator, :>, chat
    assert_equal chat, Comms::AuthorityEvidence.chat_bound
    assert_equal 2, Comms::AuthorityEvidence::LEVELS.length
    assert_equal %w[chat_bound filesystem_operator], Comms::AuthorityEvidence::LEVELS
  end

  def test_only_sanctioned_levels_can_be_minted
    error = assert_raises(Comms::ValidationError) { Comms::AuthorityEvidence.from('root') }
    assert_match(/evidence must be one of/, error.message)
    assert_raises(Comms::ValidationError) { Comms::AuthorityEvidence.new('any_string') }
  end

  def test_no_actor_kind_mapping_can_grant_operator_evidence
    refute_respond_to Comms::AuthorityEvidence, :from_actor_kind
    error = assert_raises(Comms::ValidationError) { Comms::AuthorityEvidence.from('os_user') }
    assert_match(/evidence must be one of/, error.message)
  end

  def test_evidence_round_trips_through_its_persisted_form
    assert_equal 'chat_bound', Comms::AuthorityEvidence.from('chat_bound').to_s
    assert_equal 'filesystem_operator', Comms::AuthorityEvidence.from('filesystem_operator').to_s
    assert_predicate Comms::AuthorityEvidence.from('filesystem_operator'), :filesystem_operator?
    assert_predicate Comms::AuthorityEvidence.chat_bound, :chat_bound?
  end

  # INV-C + INV-D lock: the v1 policy ignores its input entirely and returns
  # filesystem_operator for every effect, including a hostile model-shaped
  # descriptor that tries to declare itself cheap.
  def test_v1_policy_requires_filesystem_operator_for_every_effect
    hostile = { 'tool' => 'rm', 'target' => '/', 'kind' => 'approve_tool',
                'required_evidence' => 'chat_bound' }

    [nil, {}, { 'kind' => 'approve_tool' }, hostile].each do |effect|
      assert_equal 'filesystem_operator',
                   Comms::ApprovalPolicy.required_evidence(effect).to_s,
                   "effect #{effect.inspect} must require filesystem_operator (INV-D)"
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
