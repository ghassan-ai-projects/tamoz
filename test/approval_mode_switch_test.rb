# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'

# Step 7B engine semantics (ADR §2.6): rebind_session swaps ONE session's
# (profile, policy_rev) for the next decide only; tightening drops old-rev
# grants for free; a global reload stays invisible to the bound session; every
# applied switch lands in the decision log exactly once per switch id.
class ApprovalModeSwitchTest < Minitest::Test
  Approval = Tamoz::Approval
  include ApprovalCase

  def test_loosen_rebind_auto_allows_the_next_decide
    eng = build_engine(profile: 'implement')
    eng.bind_session('s1')
    request = run_check_request(eng, 's1')

    assert_equal :ask, eng.decide(request).verdict

    rev = eng.rebind_session(profile: 'auto', session_id: 's1')

    assert_equal auto_rev, rev
    decision = eng.decide(request)
    assert_equal :allow, decision.verdict, 'the loosened mode must govern the next decide'
    assert_equal rev, decision.policy_rev
  end

  def test_tighten_rebind_drops_the_session_grant_by_rev_mismatch
    eng = build_engine(profile: 'implement')
    eng.bind_session('s1')
    request = run_check_request(eng, 's1')
    ask = eng.decide(request)
    eng.resolve(decision_id: ask.id, answer: :approve, scope: :session)

    tightened = eng.rebind_session(profile: 'review', session_id: 's1')
    next_ask = eng.decide(run_check_request(eng, 's1'))

    assert_equal :ask, next_ask.verdict,
                 'a grant minted under the old rev must stop matching after a tighten'
    assert_equal tightened, next_ask.policy_rev
    assert next_ask.grant_offer, 'the tightened mode must offer grants going forward'
  end

  def test_loosening_mints_forward_and_never_resurrects_old_rev_grants
    eng = build_engine(profile: 'plan')
    eng.bind_session('s1')
    write_request = eng.build_request(
      tool: 'create_file', argv: [], targets: ['/workspace/new.txt'],
      effect_class: :bounded, session_id: 's1'
    )
    assert_equal :deny, eng.decide(write_request).verdict

    eng.rebind_session(profile: 'auto', session_id: 's1')
    allowed = eng.decide(write_request)

    assert_equal :allow, allowed.verdict
    refute allowed.id.end_with?('/grant'),
           'an allow after loosening comes from the tier default, not a resurrected grant'
  end

  def test_rebind_never_redecides_an_already_recorded_decision
    log = Approval::MemoryDecisionLog.new
    eng = build_engine(profile: 'implement', decision_log: log)
    eng.bind_session('s1')
    request = run_check_request(eng, 's1')
    recorded = eng.decide(request)

    eng.rebind_session(profile: 'plan', session_id: 's1')

    stored = log.lookup(recorded.id)
    assert_equal recorded.verdict, stored.fetch(:decision).verdict
    assert_equal recorded.policy_rev, stored.fetch(:policy_rev),
                 'the switch governs only the next decide, nothing retroactive'
  end

  def test_a_parked_ask_resolves_against_its_issuing_decision_after_a_switch
    eng = build_engine(profile: 'implement')
    eng.bind_session('s1')
    request = run_check_request(eng, 's1')
    ask = eng.decide(request)

    eng.rebind_session(profile: 'plan', session_id: 's1')
    grant = eng.resolve(decision_id: ask.id, answer: :approve, scope: :once)

    assert_equal ask.policy_rev, grant.policy_rev,
                 'the resolution binds its issuing decision, not the current rev'
  end

  def test_switch_is_scoped_to_one_session_and_never_leaks
    eng = build_engine(profile: 'implement')
    eng.bind_session('s1')
    eng.bind_session('s2')

    eng.rebind_session(profile: 'auto', session_id: 's1')

    assert_equal :allow, eng.decide(run_check_request(eng, 's1')).verdict
    assert_equal :ask, eng.decide(run_check_request(eng, 's2')).verdict,
                 'MS-5: the rebind is session-scoped and never global'
  end

  def test_global_reload_stays_invisible_to_the_rebound_session
    with_policy(MINIMAL_AUTO_BASE) do |_path|
      eng = build_engine(profile: 'implement')
      eng.bind_session('s1')
      eng.bind_session('s2')
      eng.rebind_session(profile: 'auto', session_id: 's1')

      eng.reload(policy_document_for('review'))

      assert_equal :allow, eng.decide(run_check_request(eng, 's1')).verdict,
                   'the chosen mode survives a global reload'
      assert_equal :ask, eng.decide(run_check_request(eng, 's2')).verdict,
                   'an unbound session follows the global reload'
    end
  end

  def test_mode_switch_is_logged_with_actor_from_and_to
    clock = ManualClock.new
    log = Approval::MemoryDecisionLog.new
    eng = build_engine(profile: 'implement', decision_log: log, clock: clock)
    eng.bind_session('s1')
    from_rev = eng.policy.policy_rev

    to_rev = eng.rebind_session(profile: 'auto', session_id: 's1', actor_id: 'ops', switch_id: 'sw-1')
    record = log.lookup_mode_switch('sw-1')

    assert_equal 's1', record.fetch(:session_id)
    assert_equal 'ops', record.fetch(:actor_id)
    assert_equal from_rev, record.fetch(:from_rev)
    assert_equal to_rev, record.fetch(:to_rev)
    assert_equal clock.call, Time.at(record.fetch(:ts_ms) / 1000.0)
  end

  def test_replayed_switch_appends_one_record_for_the_same_switch_id
    log = Approval::MemoryDecisionLog.new
    eng = build_engine(profile: 'implement', decision_log: log)
    eng.bind_session('s1')
    first = eng.rebind_session(profile: 'auto', session_id: 's1', actor_id: 'ops', switch_id: 'sw-1')

    replayed = eng.rebind_session(profile: 'auto', session_id: 's1', actor_id: 'ops', switch_id: 'sw-1')

    assert_equal first, replayed
    assert log.lookup_mode_switch('sw-1'), 'the audit record exists'
  end

  def test_same_switch_id_with_different_content_is_a_conflict
    log = Approval::MemoryDecisionLog.new
    eng = build_engine(profile: 'implement', decision_log: log)
    eng.bind_session('s1')
    eng.rebind_session(profile: 'auto', session_id: 's1', actor_id: 'ops', switch_id: 'sw-1')

    error = assert_raises(Approval::ConflictingResolutionError) do
      log.record_mode_switch(
        id: 'sw-1', session_id: 's1', actor_id: 'ops',
        from_rev: 'other-rev', to_rev: 'also-other',
        profile_name: 'auto', ts_ms: 1
      )
    end

    assert_match(/different content/, error.message)
  end

  def test_unknown_mode_fails_closed_without_touching_the_binding
    eng = build_engine(profile: 'implement')
    eng.bind_session('s1')

    assert_raises(Approval::InvalidPolicyError) do
      eng.rebind_session(profile: 'nonexistent', session_id: 's1')
    end

    assert_equal :ask, eng.decide(run_check_request(eng, 's1')).verdict
    refute_equal 'nonexistent', eng.policy.profile_name
  end

  private

  def run_check_request(eng, session_id)
    eng.build_request(
      tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'],
      effect_class: :bounded, session_id: session_id
    )
  end

  def auto_rev
    Approval::PolicyDocument.load_profile(
      base_path, 'auto', evidence_symbols: evidence_symbols
    ).policy_rev
  end

  # A base whose review tier asks, so a reload to it is observable on s2.
  def policy_document_for(profile)
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'base.yaml'), MINIMAL_AUTO_BASE)
    FileUtils.mkdir_p(File.join(dir, 'profiles'))
    File.write(File.join(dir, 'profiles', "#{profile}.yaml"), "version: 1\nprofile:\n  name: #{profile}\n")
    doc = Approval::PolicyDocument.load_profile(
      File.join(dir, 'base.yaml'), profile, evidence_symbols: evidence_symbols
    )
    FileUtils.remove_entry(dir)
    doc
  end

  MINIMAL_AUTO_BASE = <<~YAML
    version: 1
    tool_tiers:
      run_check:
        tier: local_execute
        verb: execute
        key_argv: [0]
    fallback_tier:
      tier: local_execute
      verb: unknown
      grant_scopes: [once]
    tiers:
      read:
        default: allow
      workspace_write:
        default: allow
      local_execute:
        default: ask
        grant_scopes: [once, session]
      network:
        default: ask
        grant_scopes: [once]
      external_publish:
        default: ask
        grant_scopes: [once]
      destructive:
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
    simulations: []
  YAML
end
