# frozen_string_literal: true

require_relative 'test_helper'

# DR-2 §2/§4 — the circuit record's `rate` and `run` predicates.
#
# These two condition kinds ship in production scopes (`schedule` and
# `rule_target` both carry `budget_exceeded`, a rate; `rule_target` carries
# `fingerprint_repeat_in_run`) and had no test of their own: the only coverage
# was through `sqlite_circuit_store_test`, which exercises consecutive, window,
# and immediate only. A broken rate predicate would silently never open a
# budget circuit — a safety engine failing in the invisible direction.
#
# Every row here drives the value directly, because that is the narrowest
# boundary at which the arithmetic is observable.
class CircuitRecordTest < Minitest::Test
  Circuit = Tamoz::Circuit
  Record = Tamoz::Circuit::Record

  NOW = 1_700_000_000_000
  OWNER = 'worker:a'
  RATE_WINDOW_MS = 900_000

  # The shipped `budget_exceeded` condition, alone in a scope.
  #
  # The production `schedule` scope also carries a 3-strike CONSECUTIVE
  # condition, which opens first and would mask every rate assertion below.
  # Isolating the predicate is the point: these rows are about the rate
  # arithmetic, and `test_the_shipped_schedule_scope_carries_a_rate_condition`
  # keeps them tied to what actually ships.
  RATE_ONLY = Tamoz::Circuit::Registry::Scope.new(
    scope_type: 'schedule',
    conditions: [
      Tamoz::Circuit::Registry::Condition.new(
        id: 'budget_exceeded', kind: 'rate', window_ms: RATE_WINDOW_MS,
        max_rate: 0.5, min_samples: 4
      )
    ],
    reset_authority: 'owner',
    evidence_rule: 'owner_or_evals',
    in_flight_rule: 'complete_and_journal',
    escalation_owner: 'schedule_owner'
  )

  def schedule_record
    Record.initial(scope: RATE_ONLY, scope_id: 'nightly', now_ms: NOW)
  end

  # The isolated scope above must keep describing something real.
  def test_the_shipped_schedule_scope_carries_a_rate_condition
    shipped = Tamoz::Circuit::Registry.fetch('schedule').condition('budget_exceeded')

    assert_equal 'rate', shipped.kind
    assert_equal RATE_ONLY.condition('budget_exceeded'), shipped
  end

  def rule_record
    Record.initial(scope: 'rule_target', scope_id: 'target.a', now_ms: NOW)
  end

  def fail(record, at:, kind: :budget, **rest)
    record.with_failure(owner_id: OWNER, kind:, now_ms: at, **rest)
  end

  def succeed(record, at:)
    record.with_success(owner_id: OWNER, now_ms: at)
  end

  # --- rate: min_samples ---------------------------------------------------

  # The production condition is `max_rate: 0.5, min_samples: 4` over a 15
  # minute window. Below the sample floor the ratio is not yet evidence, no
  # matter how bad it looks.
  def test_a_rate_condition_does_not_open_below_its_sample_floor
    record = schedule_record
    3.times { |index| record = fail(record, at: NOW + index) }

    assert_equal 'closed', record.state, '3 failures is under min_samples 4'
  end

  def test_a_rate_condition_opens_once_the_sample_floor_is_met
    record = schedule_record
    4.times { |index| record = fail(record, at: NOW + index) }

    assert_equal 'open', record.state
    met = record.conditions_met.map { |entry| entry['condition'] }

    assert_includes met, 'budget_exceeded'
  end

  # --- rate: the ratio itself ---------------------------------------------

  # Successes are counted too — that is what makes this a RATE rather than a
  # failure count. Successes land first so the ratio is never momentarily over
  # the ceiling on the way to its final value.
  def test_a_rate_condition_stays_closed_when_successes_dilute_the_ratio
    record = schedule_record
    3.times { |index| record = succeed(record, at: NOW + index) }
    2.times { |index| record = fail(record, at: NOW + 10 + index) }

    assert_equal 'closed', record.state, '2 failures in 5 outcomes is 0.4, under 0.5'
  end

  # Exactly at the ceiling opens: the predicate is `>=`, so 0.5 is spent, not
  # spare. One fewer failure over the same samples would be 0.25 and closed.
  def test_a_rate_condition_opens_at_exactly_the_ceiling
    record = schedule_record
    2.times { |index| record = succeed(record, at: NOW + index) }
    2.times { |index| record = fail(record, at: NOW + 10 + index) }

    assert_equal 'open', record.state, '2 failures in 4 outcomes is exactly 0.5'
  end

  # --- rate: the window ----------------------------------------------------

  # Evidence older than the window is pruned before the ratio is taken, so a
  # burst from an hour ago cannot open a circuit today.
  def test_a_rate_condition_prunes_evidence_older_than_its_window
    record = schedule_record
    3.times { |index| record = fail(record, at: NOW + index) }

    assert_equal 'closed', record.state

    # The fourth failure arrives after the window has rolled past the first
    # three. One live sample is left, which is under min_samples.
    record = fail(record, at: NOW + RATE_WINDOW_MS + 1_000)

    assert_equal 'closed', record.state,
                 'a stale burst must not combine with a fresh failure to open'
  end

  # --- run -----------------------------------------------------------------

  # `fingerprint_repeat_in_run` is threshold 3: the SAME failure signature three
  # times inside one run is the evidence, not three failures generally.
  def test_a_run_condition_counts_repeats_of_one_fingerprint
    record = rule_record
    2.times do |index|
      record = fail(record, at: NOW + index, kind: :fingerprint_recurrence,
                            run_id: 'run.1', fingerprint: 'sha256:aaa')
    end

    assert_equal 'closed', record.state

    record = fail(record, at: NOW + 2, kind: :fingerprint_recurrence,
                          run_id: 'run.1', fingerprint: 'sha256:aaa')

    assert_equal 'open', record.state
  end

  def test_a_run_condition_does_not_aggregate_across_fingerprints
    record = rule_record
    %w[sha256:aaa sha256:bbb sha256:ccc].each_with_index do |print, index|
      record = fail(record, at: NOW + index, kind: :fingerprint_recurrence,
                            run_id: 'run.1', fingerprint: print)
    end

    assert_equal 'closed', record.state,
                 'three DIFFERENT signatures are not one signature three times'
  end

  # The counts are scoped to the run: a new run starts from zero, or the
  # condition would be a lifetime counter wearing a run's name.
  def test_a_new_run_resets_the_fingerprint_counts
    record = rule_record
    2.times do |index|
      record = fail(record, at: NOW + index, kind: :fingerprint_recurrence,
                            run_id: 'run.1', fingerprint: 'sha256:aaa')
    end
    record = fail(record, at: NOW + 5, kind: :fingerprint_recurrence,
                          run_id: 'run.2', fingerprint: 'sha256:aaa')

    assert_equal 'closed', record.state
    counts = record.owners.dig(OWNER, 'conditions', 'fingerprint_repeat_in_run')

    assert_equal 'run.2', counts.fetch('run_id')
    assert_equal({ 'sha256:aaa' => 1 }, counts.fetch('counts'))
  end

  # A run condition without the run or the signature it counts has nothing to
  # count. It fails closed rather than accumulating a blank key.
  def test_a_run_condition_refuses_a_failure_that_names_no_run
    record = rule_record

    assert_raises(Tamoz::ConfigurationError) do
      fail(record, at: NOW, kind: :fingerprint_recurrence, fingerprint: 'sha256:aaa')
    end
    assert_raises(Tamoz::ConfigurationError) do
      fail(record, at: NOW, kind: :fingerprint_recurrence, run_id: 'run.1')
    end
  end

  # --- bounds --------------------------------------------------------------

  # DR-2 C2/C8: the count map is bounded, and the bound must not be able to
  # evict the evidence that is closest to opening the circuit — or a noisy run
  # could hide the repeat it was watching for.
  def repeat(record, print, times:, from:)
    times.times do |index|
      record = fail(record, at: from + index, kind: :fingerprint_recurrence,
                            run_id: 'run.1', fingerprint: print)
    end
    record
  end

  # A flood of one-off signatures must not evict the one that is closest to its
  # threshold, or a noisy run could hide the repeat the condition watches for.
  def test_the_fingerprint_count_map_keeps_the_evidence_nearest_its_threshold
    limit = Circuit::MAX_RUN_FINGERPRINTS
    record = repeat(rule_record, 'sha256:hot', times: 2, from: NOW)
    (limit + 5).times do |index|
      record = repeat(record, "sha256:cold#{index}", times: 1, from: NOW + 10 + index)
    end
    counts = record.owners.dig(OWNER, 'conditions', 'fingerprint_repeat_in_run', 'counts')

    assert_operator counts.length, :<=, limit + 1
    assert_equal 2, counts['sha256:hot']
  end

  def test_a_bounded_count_map_still_opens_on_the_repeat_it_was_watching
    record = repeat(rule_record, 'sha256:hot', times: 2, from: NOW)
    (Circuit::MAX_RUN_FINGERPRINTS + 5).times do |index|
      record = repeat(record, "sha256:cold#{index}", times: 1, from: NOW + 10 + index)
    end

    assert_equal 'open', repeat(record, 'sha256:hot', times: 1, from: NOW + 200).state
  end

  # --- immutability --------------------------------------------------------

  # The header claims "every transition returns a NEW record". `load` used to
  # store the caller's hash by reference and `owners` handed the live container
  # back out, so any holder could mutate durable state in place.
  def test_a_loaded_record_cannot_be_mutated_through_its_accessors
    payload = schedule_record.to_payload
    loaded = Record.load(payload, scope: 'schedule')

    assert_raises(FrozenError) { loaded.owners['intruder'] = {} }
    assert_raises(FrozenError) { loaded.conditions_met << {} }
    # And the caller's own hash is not aliased into the record.
    payload['state'] = 'open'

    assert_equal 'closed', loaded.state
  end
end
