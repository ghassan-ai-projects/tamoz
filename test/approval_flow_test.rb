# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'

# Phase 7 flow seams at the engine and prompt boundaries: session teardown
# deleting remembered grants, and the interactive scope follow-up contract.
class ApprovalFlowTest < Minitest::Test
  include ApprovalCase

  POLICY = <<~YAML
    version: 1
    tool_tiers:
      run_check:
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
    grant_keys:
      local_execute: [verb, tool]
    rules: []
    evidence:
      approve: filesystem_operator
      deny: chat_bound
    simulations: []
    ask:
      timeout_s: 300
      on_timeout: park
  YAML

  def test_close_session_purges_remembered_grants_so_the_next_ask_prompts_again
    with_policy(POLICY) do |path|
      clock = ApprovalCase::ManualClock.new
      engine = build_engine(policy: load_policy_document(path), clock: clock)
      engine.bind_session('profile:default')
      ask = -> { engine.decide(build_request(engine)) }

      decision = ask.call
      assert_equal :ask, decision.verdict

      engine.resolve(decision_id: decision.id, answer: :approve, scope: :session)
      assert_equal :allow, ask.call.verdict,
                   'the remembered session grant must allow the repeat'

      engine.close_session('profile:default')
      assert_equal :ask, ask.call.verdict,
                   'teardown must delete the session grants'
    end
  end

  def test_scope_follow_up_is_offered_only_when_the_offer_includes_session
    require 'stringio'
    require 'tamoz/agent'
    offered = { 'decision' => { 'grant_scopes' => %w[once session] } }

    affirming = Tamoz::Agent::CLI::PromptAdapter.new(input: StringIO.new("y\n"), err: StringIO.new)
    assert_equal true, affirming.remember_for_session(offered),
                 'an affirming answer remembers for the session'

    plain = Tamoz::Agent::CLI::PromptAdapter.new(input: StringIO.new("\n"), err: StringIO.new)
    assert_equal false, plain.remember_for_session(offered),
                 'a bare Enter keeps the grant to this one ask'

    once_only = { 'decision' => { 'grant_scopes' => %w[once] } }
    untouched = Tamoz::Agent::CLI::PromptAdapter.new(input: StringIO.new("y\n"), err: StringIO.new)
    assert_equal false, untouched.remember_for_session(once_only),
                 'no follow-up is prompted when the offer lacks :session'
  end

  private

  def build_request(engine)
    engine.build_request(
      tool: 'run_check', argv: ['lint'], targets: [],
      effect_class: :bounded, session_id: 'profile:default'
    )
  end
end
