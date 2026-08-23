# frozen_string_literal: true

require_relative 'test_helper'
require 'tempfile'

# Approval redesign phase 2 — policy data loader/validator.
class ApprovalPolicyDocumentTest < Minitest::Test
  Approval = Tamoz::Approval

  def base_path
    ROOT.join('gems', 'tamoz-approval', 'policy', 'base.yaml')
  end

  def evidence_symbols
    %i[filesystem_operator chat_bound]
  end

  def test_bundled_base_loads_and_validates
    document = Approval::PolicyDocument.load(base_path, evidence_symbols: evidence_symbols)

    assert_equal 1, document.version
    assert_match(/\A[0-9a-f]{64}\z/, document.policy_rev)
    assert_equal :ask, document.tiers[:local_execute][:default]
    assert_equal %i[once session], document.tiers[:local_execute][:grant_scopes]
  end

  def test_bundled_profiles_load
    %w[implement review unattended].each do |name|
      document = Approval::PolicyDocument.load_profile(base_path, name, evidence_symbols: evidence_symbols)

      assert_equal name, document.profile_name
      assert_match(/\A[0-9a-f]{64}\z/, document.policy_rev)
    end
  end

  def test_profile_overrides_tier_defaults
    document = Approval::PolicyDocument.load_profile(base_path, 'review', evidence_symbols: evidence_symbols)

    assert_equal :ask, document.tiers[:workspace_write][:default]
    assert_equal :ask, document.tiers[:local_execute][:default]
  end

  def test_unattended_profile_changes_timeout_behavior
    document = Approval::PolicyDocument.load_profile(base_path, 'unattended', evidence_symbols: evidence_symbols)

    assert_equal :deny, document.ask[:on_timeout]
  end

  def test_digest_changes_on_content_edit
    document = Approval::PolicyDocument.load(base_path, evidence_symbols: evidence_symbols)
    other = Approval::PolicyDocument.load(base_path, evidence_symbols: evidence_symbols)

    assert_equal document.policy_rev, other.policy_rev

    # Different profile → different rev.
    review = Approval::PolicyDocument.load_profile(base_path, 'review', evidence_symbols: evidence_symbols)
    refute_equal document.policy_rev, review.policy_rev
  end

  def test_unknown_profile_name_fails_at_load
    error = assert_raises(Approval::InvalidPolicyError) do
      Approval::PolicyDocument.load_profile(base_path, 'missing', evidence_symbols: evidence_symbols)
    end

    assert_match(/unknown profile/, error.message)
  end

  def test_invalid_yaml_is_rejected
    write_policy_yaml('version: [') do |path|
      assert_raises(Approval::InvalidPolicyError) { Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols) }
    end
  end

  def test_missing_required_key_is_rejected
    write_policy_yaml('version: 1') do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/missing required key|policy document structure error/, error.message)
    end
  end

  def test_tool_tiers_references_unknown_tier
    write_policy_yaml(<<~YAML) do |path|
      version: 1
      tool_tiers:
        read_file:
          tier: unknown_tier
          verb: read
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
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/unknown tier/, error.message)
    end
  end

  def test_child_task_may_not_offer_session_scope
    write_policy_yaml(<<~YAML) do |path|
      version: 1
      tool_tiers:
        child_task:
          tier: local_execute
          verb: execute
          grant_scopes: [once, session]
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: ask
          grant_scopes: [once, session]
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
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/child_task.*grant_scopes may not include :session/, error.message)
    end
  end

  def test_network_tier_may_not_offer_session_scope
    write_policy_yaml(<<~YAML) do |path|
      version: 1
      tool_tiers: {}
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        network:
          default: ask
          grant_scopes: [once, session]
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
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/network grant_scopes may not include :session/, error.message)
    end
  end

  def test_unknown_rule_verdict_is_rejected
    write_policy_yaml(<<~YAML) do |path|
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
      rules:
        - id: bad
          match:
            tool: anything
          verdict: maybe
          reason: nope
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/verdict must be one of/, error.message)
    end
  end

  def test_unknown_rule_matcher_is_rejected
    write_policy_yaml(<<~YAML) do |path|
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
      rules:
        - id: bad
          match:
            unknown_matcher: value
          verdict: ask
          reason: nope
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
    YAML
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/unknown matchers/, error.message)
    end
  end

  def test_evidence_typo_rejected_at_load
    write_policy_yaml(<<~YAML) do |path|
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
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operater
        deny: chat_bound
      simulations: []
    YAML
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/evidence symbol.*is not in the injected symbol set/, error.message)
    end
  end

  def test_simulation_failure_rejects_document
    write_policy_yaml(<<~YAML) do |path|
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
          match:
            verb: read
            target_glob: "**/.env*"
          verdict: deny
          reason: credential files
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations:
        - request:
            tool: read_file
            verb: read
            targets: ["**/.env"]
          expect: allow
    YAML
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/simulation failed/, error.message)
    end
  end

  def test_deny_rules_evaluate_before_ask_allow_rules
    write_policy_yaml(<<~YAML) do |path|
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
        - id: allow-everything
          match:
            verb: read
          verdict: allow
          reason: broad allow
        - id: credential-files
          match:
            verb: read
            target_glob: "**/.env*"
          verdict: deny
          reason: credential files
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations:
        - request:
            tool: read_file
            verb: read
            targets: ["**/.env"]
          expect: deny
    YAML
      assert Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
    end
  end

  def test_local_execute_with_full_key_offers_session_scope
    write_policy_yaml(<<~YAML) do |path|
      version: 1
      tool_tiers:
        run_check:
          tier: local_execute
          verb: execute
          key_argv: [0]
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: ask
          grant_scopes: [once, session]
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
      document = Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      simulator = Approval::Evaluator.new(document)
      request = Approval::Request.new(
        tool: :run_check,
        verb: :execute,
        argv: ['lint'],
        targets: ['/workspace/src'],
        effect_class: :bounded,
        session_id: 's1'
      )
      decision = simulator.evaluate(request)

      assert_equal :ask, decision.verdict
      assert decision.grant_offer
      assert_includes decision.grant_offer.scopes, :session
    end
  end

  def test_ask_allow_rule_matches
    write_policy_yaml(<<~YAML) do |path|
      version: 1
      tool_tiers:
        git:
          tier: local_execute
          verb: execute
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: allow
          grant_scopes: [once, session]
      grant_keys:
        local_execute: [verb, tool]
      rules:
        - id: force-push
          match:
            argv_prefix: ["git", "push"]
            argv_flag: "--force"
          verdict: ask
          reason: force-push
      ask:
        timeout_s: 900
        on_timeout: park
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations:
        - request:
            tool: git
            verb: execute
            argv: ["git", "push", "--force"]
          expect: ask
    YAML
      document = Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      assert_equal :ask, document.rules.first[:verdict]
    end
  end

  def test_profile_unknown_keys_rejected
    dir = Dir.mktmpdir
    base = File.join(dir, 'base.yaml')
    File.write(base, File.read(base_path))
    Dir.mkdir(File.join(dir, 'profiles'))
    File.write(File.join(dir, 'profiles', 'unknown_keys.yaml'), <<~YAML)
      profile:
        name: unknown_keys
        tools:
          approval_required: [run_check]
    YAML

    error = assert_raises(Approval::InvalidPolicyError) do
      Approval::PolicyDocument.load_profile(base, 'unknown_keys', evidence_symbols: evidence_symbols)
    end

    assert_match(/unknown keys/, error.message)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_profile_invalid_on_timeout_rejected
    dir = Dir.mktmpdir
    base = File.join(dir, 'base.yaml')
    File.write(base, File.read(base_path))
    Dir.mkdir(File.join(dir, 'profiles'))
    File.write(File.join(dir, 'profiles', 'bad_timeout.yaml'), <<~YAML)
      profile:
        name: bad_timeout
        on_timeout: panic
    YAML

    error = assert_raises(Approval::InvalidPolicyError) do
      Approval::PolicyDocument.load_profile(base, 'bad_timeout', evidence_symbols: evidence_symbols)
    end

    assert_match(/on_timeout must be :park or :deny/, error.message)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  private

  def write_policy_yaml(content)
    Tempfile.create(['policy', '.yaml']) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
