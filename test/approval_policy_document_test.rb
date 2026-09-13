# frozen_string_literal: true

require_relative 'test_helper'
require 'tempfile'
require 'yaml'

# Approval redesign phase 2 — policy data loader/validator.
class ApprovalPolicyDocumentTest < Minitest::Test
  Approval = Tamoz::Approval

  # A minimal valid document every invalid-variant test perturbs by exactly
  # one authored delta — the boilerplate the heredocs used to hand-copy.
  MINIMAL_POLICY = {
    'version' => 1,
    'tool_tiers' => {},
    'fallback_tier' => {
      'tier' => 'read', 'verb' => 'unknown', 'grant_scopes' => ['once']
    },
    'tiers' => { 'read' => { 'default' => 'allow' } },
    'grant_keys' => {},
    'rules' => [],
    'ask' => { 'timeout_s' => 900, 'on_timeout' => 'park' },
    'evidence' => { 'approve' => 'filesystem_operator', 'deny' => 'chat_bound' },
    'simulations' => []
  }.freeze

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

  def test_policy_rev_is_deterministic_and_changes_with_the_profile_overlay
    document = Approval::PolicyDocument.load(base_path, evidence_symbols: evidence_symbols)
    other = Approval::PolicyDocument.load(base_path, evidence_symbols: evidence_symbols)

    assert_equal document.policy_rev, other.policy_rev

    # Different profile → different rev.
    review = Approval::PolicyDocument.load_profile(base_path, 'review', evidence_symbols: evidence_symbols)
    refute_equal document.policy_rev, review.policy_rev
  end

  def test_tier_advertising_session_without_grant_key_is_refused_at_load
    write_policy_yaml(
      'tiers' => {
        'workspace_write' => { 'default' => 'ask', 'grant_scopes' => %w[once session] }
      }
    ) do |path|
      error = assert_raises Approval::InvalidPolicyError do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end
      assert_includes error.message, 'advertises :session'
    end
  end

  def test_no_op_profile_overlay_keeps_the_policy_rev
    write_policy_yaml(
      'tool_tiers' => {
        'run_check' => { 'tier' => 'local_execute', 'verb' => 'execute', 'key_argv' => [0] }
      },
      'tiers' => {
        'local_execute' => { 'default' => 'ask', 'grant_scopes' => %w[once session] }
      },
      'grant_keys' => { 'local_execute' => %w[verb tool target_root key_argv] }
    ) do |path|
      write_profile(File.dirname(path), 'noop', "version: 1\nprofile:\n  name: noop\n")

      plain = Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      overlayed = Approval::PolicyDocument.load_profile(path, 'noop', evidence_symbols: evidence_symbols)

      assert_equal plain.policy_rev, overlayed.policy_rev,
                   'a semantically empty overlay must not change the rev'
    end
  end

  def test_fallback_grant_scopes_may_not_include_session
    write_policy_yaml(
      'fallback_tier' => { 'grant_scopes' => %w[once session] }
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end
      assert_match(/fallback_tier grant_scopes may not include :session/, error.message)
    end
  end

  def test_unknown_profile_name_fails_at_load
    error = assert_raises(Approval::InvalidPolicyError) do
      Approval::PolicyDocument.load_profile(base_path, 'missing', evidence_symbols: evidence_symbols)
    end

    assert_match(/unknown profile/, error.message)
  end

  def test_invalid_yaml_is_rejected
    write_yaml('version: [') do |path|
      assert_raises(Approval::InvalidPolicyError) { Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols) }
    end
  end

  def test_missing_required_key_is_rejected
    write_yaml('version: 1') do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/missing required key|policy document structure error/, error.message)
    end
  end

  def test_tool_tiers_references_unknown_tier
    write_policy_yaml(
      'tool_tiers' => {
        'read_file' => { 'tier' => 'unknown_tier', 'verb' => 'read' }
      }
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/unknown tier/, error.message)
    end
  end

  def test_child_task_may_not_offer_session_scope
    write_policy_yaml(
      'tool_tiers' => {
        'child_task' => {
          'tier' => 'local_execute', 'verb' => 'execute', 'grant_scopes' => %w[once session]
        }
      },
      'tiers' => {
        'local_execute' => { 'default' => 'ask', 'grant_scopes' => %w[once session] }
      }
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/child_task.*grant_scopes may not include :session/, error.message)
    end
  end

  def test_network_tier_may_not_offer_session_scope
    write_policy_yaml(
      'tiers' => {
        'network' => { 'default' => 'ask', 'grant_scopes' => %w[once session] }
      }
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/network grant_scopes may not include :session/, error.message)
    end
  end

  def test_unknown_rule_verdict_is_rejected
    write_policy_yaml(
      'rules' => [rule(id: 'bad', match: { 'tool' => 'anything' }, verdict: 'maybe', reason: 'nope')]
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/verdict must be one of/, error.message)
    end
  end

  def test_unknown_rule_matcher_is_rejected
    write_policy_yaml(
      'rules' => [rule(id: 'bad', match: { 'unknown_matcher' => 'value' }, verdict: 'ask', reason: 'nope')]
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/unknown matchers/, error.message)
    end
  end

  def test_evidence_typo_rejected_at_load
    write_policy_yaml(
      'evidence' => { 'approve' => 'filesystem_operater' }
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/evidence symbol.*is not in the injected symbol set/, error.message)
    end
  end

  def test_simulation_failure_rejects_document
    write_policy_yaml(
      'tool_tiers' => { 'read_file' => { 'tier' => 'read', 'verb' => 'read' } },
      'rules' => [credential_files_rule(verdict: 'deny')],
      'simulations' => [simulation(
        tool: 'read_file', verb: 'read', targets: ['**/.env'], expect: 'allow'
      )]
    ) do |path|
      error = assert_raises(Approval::InvalidPolicyError) do
        Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      end

      assert_match(/simulation failed/, error.message)
    end
  end

  def test_deny_rules_evaluate_before_ask_allow_rules
    write_policy_yaml(
      'tool_tiers' => { 'read_file' => { 'tier' => 'read', 'verb' => 'read' } },
      'rules' => [
        rule(id: 'allow-everything', match: { 'verb' => 'read' }, verdict: 'allow', reason: 'broad allow'),
        credential_files_rule(verdict: 'deny')
      ],
      'simulations' => [simulation(
        tool: 'read_file', verb: 'read', targets: ['**/.env'], expect: 'deny'
      )]
    ) do |path|
      assert Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
    end
  end

  def test_local_execute_with_full_key_offers_session_scope
    write_policy_yaml(
      'tool_tiers' => {
        'run_check' => { 'tier' => 'local_execute', 'verb' => 'execute', 'key_argv' => [0] }
      },
      'tiers' => {
        'local_execute' => { 'default' => 'ask', 'grant_scopes' => %w[once session] }
      },
      'grant_keys' => { 'local_execute' => %w[verb tool target_root key_argv] },
      'simulations' => [{
        'request' => {
          'tool' => 'run_check', 'verb' => 'execute',
          'argv' => ['lint'], 'targets' => ['/workspace/src']
        },
        'expect' => 'ask'
      }]
    ) do |path|
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
    write_policy_yaml(
      'tool_tiers' => { 'git' => { 'tier' => 'local_execute', 'verb' => 'execute' } },
      'tiers' => {
        'local_execute' => { 'default' => 'allow', 'grant_scopes' => %w[once session] }
      },
      'grant_keys' => { 'local_execute' => %w[verb tool] },
      'rules' => [rule(
        id: 'force-push',
        match: { 'argv_prefix' => %w[git push], 'argv_flag' => '--force' },
        verdict: 'ask',
        reason: 'force-push'
      )],
      'simulations' => [{
        'request' => { 'tool' => 'git', 'verb' => 'execute', 'argv' => ['git', 'push', '--force'] },
        'expect' => 'ask'
      }]
    ) do |path|
      document = Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
      assert_equal :ask, document.rules.first[:verdict]
    end
  end

  def test_profile_unknown_keys_rejected
    dir = Dir.mktmpdir
    base = File.join(dir, 'base.yaml')
    File.write(base, File.read(base_path))
    write_profile(dir, 'unknown_keys', <<~YAML)
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
    write_profile(dir, 'bad_timeout', <<~YAML)
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

  def write_policy_yaml(overrides = {}, &)
    write_yaml(YAML.dump(deep_merge(MINIMAL_POLICY, overrides)), &)
  end

  def write_yaml(content)
    Tempfile.create(['policy', '.yaml']) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end

  def write_profile(dir, name, content)
    FileUtils.mkdir_p(File.join(dir, 'profiles'))
    File.write(File.join(dir, 'profiles', "#{name}.yaml"), content)
  end

  def deep_merge(base, override)
    base.merge(override) do |_key, base_value, override_value|
      if base_value.is_a?(Hash) && override_value.is_a?(Hash)
        deep_merge(base_value, override_value)
      else
        override_value
      end
    end
  end

  def rule(id:, match:, verdict:, reason:)
    { 'id' => id, 'match' => match, 'verdict' => verdict, 'reason' => reason }
  end

  def credential_files_rule(verdict:)
    rule(
      id: 'credential-files',
      match: { 'verb' => 'read', 'target_glob' => '**/.env*' },
      verdict:,
      reason: 'credential files'
    )
  end

  def simulation(tool:, verb:, targets:, expect:)
    {
      'request' => { 'tool' => tool, 'verb' => verb, 'targets' => targets },
      'expect' => expect
    }
  end
end
