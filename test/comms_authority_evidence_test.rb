# frozen_string_literal: true

require_relative 'test_helper'

# ADR-049 / PLAN_ADR049 Phase 1 — the evidence lattice (trusted core): closed
# total order, sanctioned minting only, persistence round-trip. The v1
# constant policy is gone; prompts pin the symbol the engine's Decision
# carries (plan step 8).
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

  def test_members_exposes_the_lattice_exactly
    assert_equal %i[chat_bound filesystem_operator], Comms::AuthorityEvidence.members
    assert_equal Comms::AuthorityEvidence::LEVELS.map(&:to_sym), Comms::AuthorityEvidence.members
  end

  # The v1 constant policy is deleted: no `Comms::ApprovalPolicy` exists, and
  # the evidence a prompt pins is whatever symbol the caller passes from the
  # engine's Decision (pinned in comms_values_test and
  # comms_evidence_gated_approval_test).
  def test_the_constant_policy_is_gone
    refute Comms.const_defined?(:ApprovalPolicy, false),
           'the hardcoded evidence constant must not exist (plan step 8)'
  end
end
# rubocop:enable Minitest/MultipleAssertions
