# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'
require 'tempfile'

# Resolving answers and grant idempotence for tamoz-approval.
class ApprovalResolveTest < Minitest::Test
  Approval = Tamoz::Approval
  include ApprovalCase

  def ask_for(engine, tool:, argv:, targets:, effect_class: :bounded, session_id: 's1')
    request = engine.build_request(tool: tool, argv: argv, targets: targets, effect_class: effect_class, session_id: session_id)
    decision = engine.decide(request)
    assert_equal :ask, decision.verdict, "expected ask for #{tool} #{argv.inspect}"
    decision
  end

  def test_resolve_approve_once_mints_grant
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    grant = eng.resolve(decision_id: decision.id, answer: :approve, scope: :once)

    refute_nil grant
    assert_equal :once, grant.scope
    assert_equal decision.session_id, grant.session_id
    assert_equal decision.policy_rev, grant.policy_rev
    assert_equal decision.grant_offer.key, grant.key
  end

  def test_resolve_approve_session_mints_grant
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    grant = eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)

    refute_nil grant
    assert_equal :session, grant.scope
  end

  def test_resolve_replay_returns_recorded_grant_without_second_row
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    first = eng.resolve(decision_id: decision.id, answer: :approve, scope: :once)
    second = eng.resolve(decision_id: decision.id, answer: :approve, scope: :once)

    refute_nil first
    assert_equal first.key, second.key
    assert_equal first.scope, second.scope
    assert_equal first.session_id, second.session_id
    assert_equal first.policy_rev, second.policy_rev
    assert_equal 1, eng.grant_store.size
  end

  def test_failed_resolution_leaves_no_grant_row
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    assert_raises(Approval::InvalidScopeError) do
      eng.resolve(decision_id: decision.id, answer: :approve, scope: :lifetime)
    end
    assert_raises(ArgumentError) do
      eng.resolve(decision_id: decision.id, answer: :banana, scope: :once)
    end
    assert_equal 0, eng.grant_store.size
    assert_nil eng.decision_log.lookup_resolution(decision.id)
  end

  def test_resolve_records_actor_evidence
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    eng.resolve(decision_id: decision.id, answer: :approve, scope: :session, actor_evidence: :filesystem_operator)

    resolution = eng.decision_log.lookup_resolution(decision.id)
    assert_equal :filesystem_operator, resolution[:actor_evidence]
  end

  def test_resolve_rejects_unknown_actor_evidence_before_recording
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    error = assert_raises(ArgumentError) do
      eng.resolve(decision_id: decision.id, answer: :approve, scope: :session, actor_evidence: :filesystem_operater)
    end
    assert_match(/unknown actor evidence/, error.message)
    assert_nil eng.decision_log.lookup_resolution(decision.id)
  end

  def test_resolve_rejects_unknown_answer_with_message
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    error = assert_raises(ArgumentError) do
      eng.resolve(decision_id: decision.id, answer: :banana, scope: :once)
    end
    assert_match(/answer must be :approve or :deny/, error.message)
    assert_nil eng.decision_log.lookup_resolution(decision.id)
  end

  def test_resolve_rejects_scope_on_deny
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    error = assert_raises(Approval::InvalidScopeError) do
      eng.resolve(decision_id: decision.id, answer: :deny, scope: :session)
    end
    assert_match(/deny takes no scope/, error.message)
    assert_nil eng.grant_store.lookup(
      key: decision.grant_offer.key,
      scope: :session,
      session_id: decision.session_id,
      policy_rev: decision.policy_rev
    )
  end

  def test_expired_session_grant_never_auto_allows
    clock = ApprovalCase::ManualClock.new
    eng = build_engine(clock: clock)
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    expired_at_ms = (clock.now - 1).to_i * 1000

    grant = eng.resolve(decision_id: decision.id, answer: :approve, scope: :session, expires_at_ms: expired_at_ms)
    refute_nil grant

    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    assert_equal :ask, eng.decide(request).verdict, 'an already-expired grant must not auto-allow'
  end

  def test_resolve_conflicting_answer_raises
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    eng.resolve(decision_id: decision.id, answer: :approve, scope: :once)

    error = assert_raises(Approval::ConflictingResolutionError) do
      eng.resolve(decision_id: decision.id, answer: :deny, scope: nil)
    end
    assert_match(/already resolved/, error.message)
  end

  def test_resolve_conflicting_scope_raises
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    eng.resolve(decision_id: decision.id, answer: :approve, scope: :once)

    assert_raises(Approval::ConflictingResolutionError) do
      eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)
    end
  end

  def test_resolve_unknown_decision_raises
    eng = build_engine

    error = assert_raises(Approval::UnknownDecisionError) do
      eng.resolve(decision_id: 'no-such-id', answer: :approve, scope: :once)
    end
    assert_match(/no decision/, error.message)
  end

  def test_resolve_unoffered_scope_raises
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    assert_raises(Approval::InvalidScopeError) do
      eng.resolve(decision_id: decision.id, answer: :approve, scope: :lifetime)
    end
  end

  def test_resolve_session_scope_rejected_for_once_only_offer
    eng = build_engine
    decision = ask_for(eng, tool: 'mcp:unknown:anything', argv: [], targets: [], effect_class: :unbounded)

    assert_raises(Approval::InvalidScopeError) do
      eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)
    end
  end

  def test_resolve_deny_records_no_grant
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])
    result = eng.resolve(decision_id: decision.id, answer: :deny, scope: nil)

    assert_nil result
    assert_nil eng.grant_store.lookup(
      key: decision.grant_offer.key,
      scope: :once,
      session_id: decision.session_id,
      policy_rev: decision.policy_rev
    )

    resolution = eng.decision_log.lookup_resolution(decision.id)
    assert_equal :deny, resolution[:answer]
  end

  def test_resolve_against_stored_decision_after_reload
    eng = build_engine
    decision = ask_for(eng, tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'])

    policy_yaml = <<~YAML
      version: 1
      tool_tiers:
        run_check:
          tier: local_execute
          verb: execute
          key_argv: [0]
          grant_scopes: [once]
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: ask
          grant_scopes: [once]
      grant_keys:
        local_execute: [verb, tool, target_root, key_argv]
      rules: []
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations:
        - request:
            tool: run_check
            verb: execute
            argv: [lint]
            targets: ["/workspace/src"]
          expect: ask
    YAML
    with_policy(policy_yaml) do |path|
      eng.reload(path)
      grant = eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)

      refute_nil grant
      assert_equal :session, grant.scope
    end
  end
end
