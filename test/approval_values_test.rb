# frozen_string_literal: true

require_relative 'test_helper'

# Approval redesign phase 1 — the immutable interface vocabulary.
class ApprovalValuesTest < Minitest::Test
  Approval = Tamoz::Approval

  def test_request_fields_are_frozen
    request = Approval::Request.new(
      tool: 'read_file',
      verb: :read,
      argv: ['README.md'],
      targets: ['/workspace/README.md'],
      effect_class: :read_only,
      session_id: 'session-1'
    )

    assert_predicate request, :frozen?
    assert_equal 'read_file', request.tool
    assert_equal :read, request.verb
    assert_equal ['README.md'], request.argv
    assert_equal ['/workspace/README.md'], request.targets
    assert_equal :read_only, request.effect_class
    assert_equal 'session-1', request.session_id
  end

  def test_decision_fields_are_frozen
    offer = Approval::GrantOffer.new(scopes: [:once, :session], key: {tool: 'run_check'})
    decision = Approval::Decision.new(
      id: 'decision-1',
      verdict: :ask,
      reason: 'tier default',
      rule_id: 'tier.run_check',
      tier: :local_execute,
      grant_offer: offer,
      required_evidence: :filesystem_operator,
      policy_rev: 'rev-1'
    )

    assert_predicate decision, :frozen?
    assert_predicate decision.grant_offer, :frozen?
    assert_equal :ask, decision.verdict
    assert_equal :filesystem_operator, decision.required_evidence
  end

  def test_grant_fields_are_frozen
    grant = Approval::Grant.new(
      key: {tool: 'run_check', argv: ['lint']},
      scope: :session,
      session_id: 'session-1',
      policy_rev: 'rev-1',
      created_at_ms: 1_700_000_000_000,
      expires_at_ms: 1_700_000_001_000
    )

    assert_predicate grant, :frozen?
    assert_equal :session, grant.scope
    assert_equal 'session-1', grant.session_id
    assert_equal 'rev-1', grant.policy_rev
    assert_equal 1_700_000_000_000, grant.created_at_ms
    assert_equal 1_700_000_001_000, grant.expires_at_ms
  end

  def test_grant_offer_scopes_are_policy_chosen
    offer = Approval::GrantOffer.new(scopes: [:once], key: {})

    assert_equal [:once], offer.scopes
    assert_empty offer.key
  end

  def test_error_taxonomy_descends_from_approval_error
    assert_kind_of Class, Approval::Error
    assert Approval::InvalidPolicyError < Approval::Error
    assert Approval::ConflictingResolutionError < Approval::Error
    assert Approval::UnknownDecisionError < Approval::Error
    assert Approval::InvalidScopeError < Approval::Error
  end

  def test_error_taxonomy_descends_from_tamoz_error
    assert Approval::Error < Tamoz::Error
  end
end
