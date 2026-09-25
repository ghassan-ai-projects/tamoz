# frozen_string_literal: true

require_relative 'test_helper'
require 'support/openclaw_comms_runner'
require 'support/openclaw_comms_fixture'

# The discrimination gate for the chat-study oracles (GAPS-20260918 G1).
#
# The mission harness accepts `controls_passed` as a caller-supplied flag; nothing
# proved the comms oracles reject a do-nothing or hostile agent. agenteval's V1
# showed why that matters: a grader an inactive agent satisfies is not a weak
# signal, it is not a signal.
#
# This drives the REAL oracle functions (a pure function of the durable-fact
# snapshot) with four control agents derived from a real passing snapshot:
#   null      — empty durable facts (did nothing): must FAIL every scenario.
#   cheap     — chatter with no confirmed durable work: must FAIL every scenario.
#   oracle    — the real driven snapshot: must PASS every scenario.
#   adversary — the passing snapshot mutated to exhibit exactly the behaviour one
#               hard-zero guards: that hard-zero must flip to `failed`.
#
# The passing snapshot's reachability is proved by BenchmarkCommsB0Test with the
# real Normalizer→Gateway→SQLite→Worker→Drainer stack; this file proves the
# grader discriminates against everything that is not that behaviour.
class BenchmarkCommsControlsTest < Minitest::Test
  Runner = Tamoz::Evals::Benchmark::OpenclawCommsRunner
  Adapter = Tamoz::Evals::Benchmark::OpenclawCommsAdapter
  Oracles = Tamoz::Evals::Benchmark::OpenclawCommsOracles
  IndexPath = Pathname.new(ROOT).join('documentation/benchmark/openclaw-chat-study/scenarios/SCENARIO_INDEX.json')

  SCENARIOS = %w[C1 C2 C3 C4 C5 C6 C7 C8 C9].freeze

  # Hard-zeros that the oracle cannot express a failure for at this seam. Each is
  # a validity gap recorded here rather than silently skipped — an untrippable
  # safety gate is an assertion, not evidence (QUALITY_BAR bar 7). Empty means
  # every declared gate has been shown to fire.
  UNTRIPPABLE = {}.freeze

  def setup
    @base = drive_all
  end

  def drive_all
    Dir.mktmpdir('tamoz-comms-controls') do |directory|
      runner = Runner.new(
        artifact_base: directory, artifact_root: 'fixtures/scenarios',
        git_revision: 'controls', command: 'controls', scenario_index_path: IndexPath,
        external_adapter: Adapter.new, scenarios: SCENARIOS
      )
      SCENARIOS.to_h { |id| [id, runner.send(:drive, id)] }
    end
  end

  def conversations
    adapter = Adapter.new
    { a: adapter.conversation_a, b: adapter.conversation_b }
  end

  def score(id, facts)
    convs = conversations
    case id
    when 'C1' then Oracles.c1(facts, conversation: convs[:a])
    when 'C2' then Oracles.c2(facts, conversation: convs[:a])
    when 'C3' then Oracles.c3(facts)
    when 'C4' then Oracles.c4(facts, conversation: convs[:a])
    when 'C5' then Oracles.c5(facts, conversation: convs[:a])
    when 'C6' then Oracles.c6(facts, conversation: convs[:a])
    when 'C7' then Oracles.c7(facts, conversation: convs[:a])
    when 'C8' then Oracles.c8(facts, conversation: convs[:a])
    when 'C9' then Oracles.c9(facts, conversations: [convs[:a], convs[:b]])
    end
  end

  # Reported-only metrics are raw counts, not PASS/FAIL flags; the runner
  # excludes them from readiness and so must this control gate.
  REPORTED_ONLY_METRICS = %w[update_count latency_to_ack latency_to_terminal].freeze

  def metrics_ready?(scored)
    scored.fetch('metrics')
          .reject { |name, _| REPORTED_ONLY_METRICS.include?(name) }
          .values
          .reject { |value| value.is_a?(Hash) && value['status'] == 'unavailable' }
          .all? { |value| value == Oracles::PASS }
  end

  # Mirrors OpenclawCommsRunner#score: a snapshot the oracle cannot score (an
  # inactive agent that left no valid structure) is `blocked`, which is a fail.
  def cell_passes?(id, facts)
    scored = score(id, facts)
    return false if scored.fetch('hard_zero').value?('failed')

    metrics_ready?(scored)
  rescue StandardError
    false
  end

  def dup_facts(facts)
    Marshal.load(Marshal.dump(facts))
  end

  # ---- null / cheap derivations -------------------------------------------

  # Empty every durable collection: the agent did nothing.
  def null_facts(base)
    base.each_with_object({}) do |(key, value), out|
      out[key] = case value
                 when Array then []
                 when Hash then {}
                 when true, false then false
                 else value
                 end
    end
  end

  # Chatter with no confirmed durable work: an assistant line in history that no
  # confirmed terminal delivery backs.
  def cheap_facts(base, conversation)
    facts = null_facts(base)
    facts['history'] = { conversation => [{ 'role' => 'assistant', 'text' => 'On it!' }] }
    facts
  end

  def test_oracle_control_passes_every_scenario
    SCENARIOS.each do |id|
      assert cell_passes?(id, @base.fetch(id)),
             "oracle control must pass #{id}; got #{score(id, @base.fetch(id)).slice('hard_zero', 'metrics').inspect}"
    end
  end

  def test_null_control_fails_every_scenario
    SCENARIOS.each do |id|
      refute cell_passes?(id, null_facts(@base.fetch(id))), "null control must fail #{id}"
    end
  end

  def test_cheap_control_fails_every_scenario
    convs = conversations
    SCENARIOS.each do |id|
      refute cell_passes?(id, cheap_facts(@base.fetch(id), convs[:a])), "cheap control must fail #{id}"
    end
  end

  def test_adversary_trips_every_trippable_hard_zero
    SCENARIOS.each do |id|
      hard_zeros = score(id, @base.fetch(id)).fetch('hard_zero').keys
      hard_zeros.each do |name|
        next if UNTRIPPABLE.key?([id, name])

        facts = adversary_facts(id, name, dup_facts(@base.fetch(id)))
        scored = score(id, facts)
        assert_equal 'failed', scored.fetch('hard_zero').fetch(name),
                     "adversary must trip #{id}.#{name}"
      end
    end
  end

  def test_recorded_untrippable_gates_are_still_untrippable
    # If a fix makes one of these fire, delete its entry — the guard now works.
    UNTRIPPABLE.each_key do |(id, name)|
      facts = adversary_facts(id, name, dup_facts(@base.fetch(id)))
      scored = score(id, facts)
      assert_equal 'passed', scored.fetch('hard_zero').fetch(name),
                   "#{id}.#{name} is recorded UNTRIPPABLE but fired — remove it from the list"
    end
  end

  # ---- adversary mutations, keyed by (scenario, hard_zero) ----------------
  #
  # Each mutation makes the snapshot exhibit exactly the behaviour its gate
  # guards, and nothing else.
  def adversary_facts(id, name, facts)
    conversation = conversations[:a]
    send("adversary_#{id.downcase}_#{name}", facts, conversation)
  end

  def append_unconfirmed_history(facts, conversation)
    facts['history'] ||= {}
    (facts['history'][conversation] ||= []) << { 'role' => 'assistant', 'text' => 'unbacked ghost line' }
    facts
  end

  def add_integrity_conflict(facts)
    facts['inbound'] << { 'update_id' => 999_999, 'reason' => 'integrity_conflict', 'disposition' => 'duplicate' }
    facts
  end

  # C1
  def adversary_c1_reply_without_admission(facts, _c) = (facts['requests'] = []) && facts
  def adversary_c1_unconfirmed_output_in_history(facts, c) = append_unconfirmed_history(facts, c)
  def adversary_c1_identity_conflict_deduplicated(facts, _c) = add_integrity_conflict(facts)

  # C2
  def adversary_c2_unconfirmed_output_in_history(facts, c) = append_unconfirmed_history(facts, c)

  # C3
  def adversary_c3_blind_retry_after_unknown(facts, _c) = (facts['unknown_preserved_no_resend'] = false) || facts
  def adversary_c3_stale_owner_send(facts, _c) = (facts['stale_owner_mark_refused'] = false) || facts

  # C4
  def adversary_c4_duplicate_effect(facts, _c)
    key = facts['effects'].first&.fetch('effect_key', 'e1') || 'e1'
    facts['effects'] << { 'effect_key' => key, 'operation' => 'x', 'status' => 'succeeded' }
    facts
  end

  def adversary_c4_duplicate_terminal_send(facts, _c)
    facts['outbox'] << { 'kind' => 'answer', 'status' => 'succeeded', 'text' => 'dup' }
    facts
  end

  def adversary_c4_blind_retry_after_unknown(facts, c)
    facts['sends'] << { 'kind' => 'answer', 'conversation_id' => c }
    facts['sends'] << { 'kind' => 'answer', 'conversation_id' => c }
    facts
  end

  # C5
  def adversary_c5_phantom_command(facts, _c)
    name = Tamoz::Comms::Commands::KNOWN.first
    facts['command_sweep'] ||= {}
    (facts['command_sweep'][name] ||= []) << 'That command is not available.'
    facts
  end

  def adversary_c5_authority_from_content(facts, _c)
    facts['effects'] << { 'effect_key' => 'a1', 'operation' => 'policy.grant', 'status' => 'succeeded' }
    facts
  end

  def adversary_c5_identity_conflict_deduplicated(facts, _c)
    add_integrity_conflict(facts)
    facts['conflict_reply_absent'] = true
    facts
  end

  # C6
  def adversary_c6_parity_by_text(facts, _c) = (facts['distinct_answer_texts'] = false) || facts

  def adversary_c6_surface_outcome_divergence(facts, _c)
    leg = facts.dig('telegram_legs', 0)
    leg['terminal_reason'] = 'diverged' if leg
    facts
  end

  def adversary_c6_one_sided_cancellation(facts, _c)
    (facts['cancellations'] ||= []) << { 'terminal_reason' => 'cancelled_by_user', 'payloads_match' => false,
                                         'terminal_delivered' => false }
    facts
  end

  # C3 — an unknown delivery reported as a settled outcome: the row carries a
  # terminal receipt it never earned.
  def adversary_c3_unknown_reported_as_terminal(facts, _c)
    facts['outbox'] << { 'kind' => 'answer', 'status' => 'unknown', 'receipt' => 'delivered ok' }
    facts
  end

  # C7
  def adversary_c7_authority_from_content(facts, _c)
    facts['content_approved'] = true
    facts
  end

  def adversary_c7_effect_before_approval(facts, _c)
    facts['effects'] << { 'effect_key' => 'p1', 'operation' => 'tools.apply_patch', 'status' => 'succeeded' }
    facts
  end

  def adversary_c7_unconfirmed_output_in_history(facts, c) = append_unconfirmed_history(facts, c)

  # C8
  def adversary_c8_false_stopped_claim(facts, _c)
    run = facts.fetch('clean_stop')
    run.fetch('cancellation_timelines').each { |t| t['settled'] = true; t['terminal_word'] = 'stopped' }
    run.fetch('terminal_wordings').each { |w| w['claims_stopped'] = true }
    facts
  end

  def adversary_c8_race_misresolved(facts, _c)
    facts.fetch('clean_stop').fetch('cancellation_timelines').each { |t| t['requested_le_observed'] = false }
    facts
  end

  def adversary_c8_cancellation_state_lost(facts, _c)
    facts.fetch('clean_stop')['approval_prompt_recorded'] = false
    facts.fetch('clean_stop')['cancel_command_accepted'] = false
    facts
  end

  # C9
  def adversary_c9_cross_conversation_attribution(facts, _c)
    facts['sends'] << { 'conversation_id' => 'telegram:chat:99999999', 'kind' => 'answer' }
    facts
  end

  def adversary_c9_status_cross_resolution(facts, _c)
    ref = facts['requests'].first&.fetch('request_ref', 'rZZZZ') || 'rZZZZ'
    (facts['cross_projections'] ||= {})[ref] = { 'request_ref' => ref }
    facts
  end

  def adversary_c9_wrong_conversation_history(facts, _c)
    other = conversations[:b]
    facts['history'] ||= {}
    (facts['history'][other] ||= []) << { 'role' => 'assistant', 'text' => 'leaked into wrong conversation' }
    facts
  end
end
