# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'
require 'tempfile'
require 'fileutils'

# Engine decision matrix and canonicalization for tamoz-approval.
class ApprovalEngineTest < Minitest::Test
  Approval = Tamoz::Approval
  include ApprovalCase

  def test_read_file_normal_path_allows
    eng = build_engine
    request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/README.md'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :allow, decision.verdict
    assert_equal 'tier.read', decision.rule_id
    assert_equal :read, decision.tier
  end

  def test_read_file_env_deny
    eng = build_engine
    request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/.env'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :deny, decision.verdict
    assert_equal 'credential-files', decision.rule_id
  end

  def test_symlink_to_sensitive_file_resolves_realpath
    eng = build_engine
    Dir.mktmpdir do |dir|
      secret = File.join(dir, '.env')
      link = File.join(dir, 'link.env')
      File.write(secret, 'x')
      File.symlink(secret, link)

      request = eng.build_request(tool: 'read_file', argv: [], targets: [link], effect_class: :bounded, session_id: 's1')
      decision = eng.decide(request)

      assert_equal :deny, decision.verdict
      assert_equal 'credential-files', decision.rule_id
    end
  end

  def test_dangling_symlink_canonicalizes_without_crashing
    eng = build_engine
    Dir.mktmpdir do |dir|
      link = File.join(dir, 'gone-link')
      File.symlink(File.join(dir, 'missing'), link)

      request = eng.build_request(tool: 'read_file', argv: [], targets: [link], effect_class: :bounded, session_id: 's1')
      decision = eng.decide(request)

      assert_equal File.join(dir, 'gone-link'), request.targets.first
      assert_equal :allow, decision.verdict, 'the literal path matches no deny glob'
    end
  end

  def test_write_file_inside_workspace_allows
    eng = build_engine
    request = eng.build_request(tool: 'create_file', argv: [], targets: ['/workspace/new.txt'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :allow, decision.verdict
    assert_equal :workspace_write, decision.tier
  end

  def test_run_check_asks_with_once_and_session
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :ask, decision.verdict
    assert decision.grant_offer
    assert_includes decision.grant_offer.scopes, :once
    assert_includes decision.grant_offer.scopes, :session
  end

  def test_git_force_push_ask
    eng = build_engine
    request = eng.build_request(tool: 'git', argv: ['git', 'push', '--force'], targets: [], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :ask, decision.verdict
    assert_equal 'force-push', decision.rule_id
  end

  def test_unknown_tool_fails_closed_to_ask
    eng = build_engine
    request = eng.build_request(tool: 'unknown_tool', argv: [], targets: ['/workspace/x'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :ask, decision.verdict
    assert_equal :local_execute, decision.tier
    assert decision.grant_offer
    assert_equal [:once], decision.grant_offer.scopes
  end

  def test_unclassified_tool_with_read_only_effect_still_fails_closed
    eng = build_engine
    request = eng.build_request(tool: 'totally_unknown_tool', argv: [], targets: [], effect_class: :read_only, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :ask, decision.verdict
    assert_equal :local_execute, decision.tier
    assert_equal :unknown, request.verb
  end

  def test_unknown_effects_mcp_tool_offers_once_only
    eng = build_engine
    request = eng.build_request(tool: 'mcp:unknown:anything', argv: [], targets: [], effect_class: :unbounded, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :ask, decision.verdict
    assert decision.grant_offer
    assert_equal [:once], decision.grant_offer.scopes
  end

  def test_read_only_descriptor_forces_read_tier
    eng = build_engine
    request = eng.build_request(tool: 'apply_patch', argv: [], targets: ['/workspace/a.txt'], effect_class: :read_only, session_id: 's1')
    decision = eng.decide(request)

    assert_equal :allow, decision.verdict
    assert_equal :read, decision.tier
    assert_equal :read, request.verb
  end

  def test_deny_rules_evaluate_before_allow_rules
    policy_yaml = <<~YAML
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
          default: allow
      grant_keys: {}
      rules:
        - id: credential-files
          verdict: deny
          match:
            tool: read_file
            target_glob: "**/.env*"
          reason: credential files are never read
        - id: broad-allow-appended-last
          verdict: allow
          match:
            verb: read
          reason: broad allow after the deny
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
    with_policy(policy_yaml) do |path|
      eng = build_engine(policy: load_policy_document(path))
      request = eng.build_request(tool: 'read_file', argv: [], targets: ['/workspace/.env'], effect_class: :bounded, session_id: 's1')
      decision = eng.decide(request)

      assert_equal :deny, decision.verdict
      assert_equal 'credential-files', decision.rule_id
    end
  end

  def test_child_task_asks_every_time_with_once_only_offer
    eng = build_engine
    request = eng.build_request(tool: 'child_task', argv: ['do thing'], targets: [], effect_class: :bounded, session_id: 's1')
    first = eng.decide(request)
    second = eng.decide(request)

    assert_equal :ask, first.verdict
    assert_equal :ask, second.verdict
    assert_equal [:once], second.grant_offer.scopes
  end

  def test_session_grant_auto_allows_same_request
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(request)
    assert_equal :ask, first.verdict

    grant = eng.resolve(decision_id: first.id, answer: :approve, scope: :session)
    refute_nil grant

    second = eng.decide(request)
    assert_equal :allow, second.verdict
    assert_equal 'session grant', second.reason

    ask_record = eng.decision_log.lookup(first.id)
    hit_record = eng.decision_log.lookup(second.id)
    refute_nil ask_record
    refute_nil hit_record
    assert_equal 'ask', ask_record[:verdict]
    assert_equal 'allow', hit_record[:verdict]
    assert_equal 'engine.grant_hit', hit_record[:rule_id]
  end

  def test_session_grant_for_one_check_never_covers_another
    eng = build_engine
    lint = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(lint)
    eng.resolve(decision_id: first.id, answer: :approve, scope: :session)

    test_req = eng.build_request(tool: 'run_check', argv: ['test'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    second = eng.decide(test_req)

    assert_equal :ask, second.verdict
  end

  def test_child_task_asks_even_after_session_grant_elsewhere
    eng = build_engine
    lint = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(lint)
    eng.resolve(decision_id: first.id, answer: :approve, scope: :session)

    child = eng.build_request(tool: 'child_task', argv: ['do thing'], targets: [], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(child)

    assert_equal :ask, decision.verdict
    assert_equal [:once], decision.grant_offer.scopes
  end

  def test_expired_session_grant_stops_auto_allowing_at_the_boundary
    clock = ApprovalCase::ManualClock.new
    eng = build_engine(clock: clock)
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(request)
    expires_at_ms = (clock.now + 60).to_i * 1000

    eng.resolve(decision_id: first.id, answer: :approve, scope: :session, expires_at_ms: expires_at_ms)
    assert_equal :allow, eng.decide(request).verdict

    clock.advance(59)
    assert_equal :allow, eng.decide(request).verdict

    # Strict inequality: a grant expires AT its deadline, not after it.
    clock.advance(1)
    assert_equal :ask, eng.decide(request).verdict
  end

  def test_decide_is_idempotent_in_decision_log
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(request)
    second = eng.decide(request)

    assert_equal first.id, second.id
    record = eng.decision_log.lookup(first.id)
    refute_nil record
    assert_equal 'run_check', record[:tool]
    assert_equal 'execute', record[:verb]
    assert_equal 'ask', record[:verdict]
    assert_equal 1, eng.decision_log.records.count { |r| r[:decision_id] == first.id }
  end

  def test_decision_log_cleartext_fields_and_digest_arguments
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    record = eng.decision_log.lookup(decision.id)
    refute_nil record
    assert_equal 'run_check', record[:tool]
    assert_equal 'execute', record[:verb]
    assert_equal 'local_execute', record[:tier]
    assert_equal 'tier.local_execute', record[:rule_id]
    assert_equal 'ask', record[:verdict]
    assert_equal 'filesystem_operator', record[:evidence]
    assert_equal eng.policy.policy_rev, record[:policy_rev]

    # Arguments are digests, never cleartext; the digests cover the exact
    # canonicalized values the decision was made on.
    assert_match(/\A[0-9a-f]{64}\z/, record[:argv_digest])
    assert_match(/\A[0-9a-f]{64}\z/, record[:targets_digest])
    assert_equal Approval::Canonical.hexdigest(['lint']), record[:argv_digest]
    assert_equal Approval::Canonical.hexdigest([request.targets.first]), record[:targets_digest]
  end

  def test_unknown_tool_takes_scopes_from_fallback_field_not_the_tier_map
    policy_yaml = <<~YAML
      version: 1
      tool_tiers:
        run_check:
          tier: local_execute
          verb: execute
      fallback_tier:
        tier: local_execute
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: ask
          grant_scopes: [once, session]
      grant_keys:
        local_execute: [verb, tool, target_root]
      rules: []
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations:
        - request:
            tool: mcp:unknown:anything
            verb: unknown
            argv: []
            targets: []
          expect: ask
    YAML
    with_policy(policy_yaml) do |path|
      eng = build_engine(policy: load_policy_document(path))
      request = eng.build_request(tool: 'mcp:unknown:anything', argv: [], targets: [], effect_class: :unbounded, session_id: 's1')
      decision = eng.decide(request)

      assert_equal :ask, decision.verdict
      # The tier map carries :session, but an unclassified tool never sees it.
      assert_equal [:once], decision.grant_offer.scopes
    end
  end

  def test_session_grant_never_covers_an_unseen_second_target
    eng = build_engine
    seen = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    first = eng.decide(seen)
    eng.resolve(decision_id: first.id, answer: :approve, scope: :session)

    wider = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src', '/etc/shadow'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(wider)

    assert_equal :ask, decision.verdict, 'a target the human never saw must force a fresh ask'
  end

  def test_concurrent_replays_of_one_answer_mint_exactly_one_grant_row
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')
    decision = eng.decide(request)

    results = Array.new(8) do
      Thread.new { eng.resolve(decision_id: decision.id, answer: :approve, scope: :session) }
    end.map(&:value)

    assert_equal 1, eng.grant_store.size
    assert_equal 1, results.compact.map { |grant| [grant.key, grant.scope, grant.created_at_ms] }.uniq.size
  end

  def test_reload_failures_raise_invalid_policy_and_keep_previous_policy_live
    eng = build_engine
    previous_rev = eng.policy.policy_rev

    broken_yaml = <<~YAML
      version: 1
      tool_tiers: {}
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
      grant_keys: {}
      rules: []
      ask:
        timeout_s: &loop [*loop]
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
    with_policy(broken_yaml) do |recursive_path|
      assert_raises(Approval::InvalidPolicyError) { eng.reload('/nonexistent/policy.yaml') }
      assert_raises(Approval::InvalidPolicyError) { eng.reload(recursive_path) }
    end
    assert_equal previous_rev, eng.policy.policy_rev
  end

  def test_build_request_tolerates_nil_argv_and_targets
    eng = build_engine
    request = eng.build_request(tool: 'mcp:unknown:anything', argv: nil, targets: nil, effect_class: :unbounded, session_id: 's1')

    assert_empty request.argv
    assert_empty request.targets
  end

  def test_simulate_mirrors_decide_without_side_effects
    eng = build_engine
    request = eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1')

    before = eng.decision_log.records.size
    simulated = eng.simulate(request)

    assert_equal :ask, simulated.verdict
    assert_equal before, eng.decision_log.records.size

    decided = eng.decide(request)
    assert_equal simulated.verdict, decided.verdict
    assert_equal before + 1, eng.decision_log.records.size
  end

  # A remembered session grant covers any write under the same canonical root:
  # the second write must not ask again, and no :once row is persisted.
  def test_workspace_write_session_grant_remembers_the_root
    eng = build_engine(profile: 'review')
    first = eng.build_request(
      tool: 'apply_patch', argv: ['a.rb', 'x', 'y'],
      targets: ['/workspace/a.rb'], effect_class: :bounded, session_id: 's1'
    )
    eng.bind_session('s1')
    decision = eng.decide(first)
    assert_equal :ask, decision.verdict
    assert_includes decision.grant_offer.scopes, :session

    eng.resolve(decision_id: decision.id, answer: :approve, scope: :session)

    second = eng.build_request(
      tool: 'create_file', argv: ['b.rb', 'hi'],
      targets: ['/workspace/b.rb'], effect_class: :bounded, session_id: 's1'
    )
    next_decision = eng.decide(second)
    assert_equal :allow, next_decision.verdict
    assert_equal 'engine.grant_hit', next_decision.rule_id

    rows = eng.grant_store.instance_variable_get(:@grants)
    assert_equal 1, rows.size
    assert_equal :session, rows.first.scope
  end
end
