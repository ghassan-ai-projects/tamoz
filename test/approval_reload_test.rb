# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'
require 'tempfile'

# Policy reload and rev binding for tamoz-approval.
class ApprovalReloadTest < Minitest::Test
  Approval = Tamoz::Approval
  include ApprovalCase

  def engine
    build_engine
  end

  def test_reload_valid_policy_returns_new_rev
    eng = engine
    old_rev = eng.policy.policy_rev

    with_policy(minimal_policy(default: :ask)) do |path|
      new_rev = eng.reload(path)
      refute_equal old_rev, new_rev
      assert_equal new_rev, eng.policy.policy_rev
    end
  end

  def test_reload_invalid_policy_keeps_previous_live
    eng = engine
    old_rev = eng.policy.policy_rev

    with_policy('version: [') do |path|
      assert_raises(Approval::InvalidPolicyError) { eng.reload(path) }
      assert_equal old_rev, eng.policy.policy_rev
    end
  end

  def test_bound_session_keeps_old_rev_after_reload
    eng = engine
    eng.bind_session('s1')
    old_rev = eng.policy.policy_rev

    with_policy(minimal_policy(default: :ask)) do |path|
      eng.reload(path)
      request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's1')
      decision = eng.decide(request)

      assert_equal old_rev, decision.policy_rev
    end
  end

  def test_bound_session_canonicalizes_under_bound_rev
    eng = engine
    eng.bind_session('s1')

    with_policy(verb_flipped_policy) do |path|
      eng.reload(path)
      bound = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's1')
      fresh = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's9')

      assert_equal :read, bound.verb
      assert_equal :write, fresh.verb
      assert_equal :ask, eng.decide(fresh).verdict
    end
  end

  def test_released_session_resolves_against_current_policy
    eng = engine
    eng.bind_session('s1')
    old_rev = eng.policy.policy_rev

    with_policy(minimal_policy(default: :ask)) do |path|
      eng.reload(path)
      eng.release_session('s1')

      request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's1')
      refute_equal old_rev, eng.decide(request).policy_rev
    end
  end

  def test_new_session_uses_new_rev_after_reload
    eng = engine
    with_policy(minimal_policy(default: :ask)) do |path|
      new_rev = eng.reload(path)
      request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's2')
      decision = eng.decide(request)

      assert_equal new_rev, decision.policy_rev
      assert_equal :ask, decision.verdict
    end
  end

  def test_parked_decision_resolves_against_issuing_offer
    eng = engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)
    assert decision.grant_offer.scopes.include?(:session)

    with_policy(minimal_policy(default: :ask)) do |path|
      eng.reload(path)
      grant = eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)

      refute_nil grant
      assert_equal :session, grant.scope
    end
  end

  def test_old_rev_session_grant_does_not_match_new_session
    eng = engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)
    eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)

    with_policy(minimal_policy(default: :ask)) do |path|
      eng.reload(path)
      eng.bind_session('s2')
      second_request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's2')
      second = eng.decide(second_request)

      assert_equal :ask, second.verdict
    end
  end

  private

  def minimal_policy(default:)
    <<~YAML
      version: 1
      tool_tiers:
        read_file:
          tier: read
          verb: read
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: #{default}
      grant_keys: {}
      rules: []
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
  end

  def verb_flipped_policy
    <<~YAML
      version: 1
      tool_tiers:
        read_file:
          tier: local_execute
          verb: write
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
        local_execute: [verb, tool, target_root]
      rules: []
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
  end

  def with_policy(content)
    Tempfile.create(['policy', '.yaml']) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
