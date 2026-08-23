# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'
require 'tempfile'

# Grant-key grammar and session-scope degradation for tamoz-approval.
class ApprovalGrantKeyTest < Minitest::Test
  Approval = Tamoz::Approval
  include ApprovalCase

  def engine_for(policy_yaml)
    with_policy(policy_yaml) do |path|
      yield build_engine(policy: load_policy_document(path))
    end
  end

  def test_run_check_lint_and_test_have_distinct_keys
    policy_yaml = <<~YAML
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
    engine_for(policy_yaml) do |eng|
      lint = eng.decide(eng.build_request(tool: 'run_check', argv: ['lint'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1'))
      test = eng.decide(eng.build_request(tool: 'run_check', argv: ['test'], targets: ['/workspace/src'], effect_class: :bounded, session_id: 's1'))

      refute_equal lint.grant_offer.key, test.grant_offer.key
    end
  end

  def test_no_path_target_degrades_to_once
    policy_yaml = <<~YAML
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
          expect: ask
    YAML
    engine_for(policy_yaml) do |eng|
      decision = eng.decide(eng.build_request(tool: 'run_check', argv: ['lint'], targets: [], effect_class: :bounded, session_id: 's1'))

      assert decision.grant_offer
      assert_equal [:once], decision.grant_offer.scopes
      assert_empty decision.grant_offer.key
    end
  end

  def test_child_task_offer_once_only
    engine_for(base_like) do |eng|
      decision = eng.decide(eng.build_request(tool: 'child_task', argv: ['do thing'], targets: [], effect_class: :bounded, session_id: 's1'))

      assert_equal [:once], decision.grant_offer.scopes
    end
  end

  def test_network_tool_offer_once_only
    policy_yaml = <<~YAML
      version: 1
      tool_tiers:
        post_webhook:
          tier: network
          verb: publish
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        network:
          default: ask
          grant_scopes: [once]
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
    engine_for(policy_yaml) do |eng|
      decision = eng.decide(eng.build_request(tool: 'post_webhook', argv: [], targets: ['https://example.com'], effect_class: :bounded, session_id: 's1'))

      assert_equal :ask, decision.verdict
      assert_equal [:once], decision.grant_offer.scopes
    end
  end

  private

  def base_like
    <<~YAML
      version: 1
      tool_tiers:
        read_file:
          tier: read
          verb: read
        run_check:
          tier: local_execute
          verb: execute
          key_argv: [0]
        child_task:
          tier: local_execute
          verb: execute
          grant_scopes: [once]
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
  end

  def with_policy(content)
    Tempfile.create(['policy', '.yaml']) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
