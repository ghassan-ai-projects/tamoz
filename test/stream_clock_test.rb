# frozen_string_literal: true

require_relative 'test_helper'

# The injected clocks are the determinism boundary: every stream-owned
# timestamp comes from one of them, so a clock that can silently go backwards
# makes replay unreproducible. These rows exist because the guard was DEAD —
# `ReplayClock` compared against a mark it never updated, and `WallClock`
# guarded nothing at all on the event side. A guard with no test is a comment.
class StreamClockTest < Minitest::Test
  Stream = Tamoz::Stream

  def test_replay_processing_time_is_the_virtual_time
    clock = Stream::ReplayClock.new(start: 100)

    assert_equal 100, clock.now_processing
    assert_equal 105, clock.advance(5)
    assert_equal 105, clock.now_processing
  end

  def test_replay_event_time_may_repeat
    clock = Stream::ReplayClock.new(start: 100)

    assert_equal 50, clock.now_event(50)
    assert_equal 50, clock.now_event(50), 'a watermark that stands still is not a regression'
    assert_equal 51, clock.now_event(51)
  end

  # The bug this file was written for: `now_event(60)` after `now_event(70)`
  # used to pass, because nothing ever recorded 70 as the high-water mark.
  def test_replay_event_time_cannot_regress
    clock = Stream::ReplayClock.new(start: 100)
    clock.now_event(70)
    error = assert_raises(Stream::StreamClockError) { clock.now_event(60) }
    assert_match(/regressed from 70 to 60/, error.message)
  end

  def test_wall_event_time_cannot_regress_either
    clock = Stream::WallClock.new(now: 1_700_000_000)
    clock.now_event(70)

    assert_equal 70, clock.now_event(70)
    assert_raises(Stream::StreamClockError) { clock.now_event(69) }
  end

  # Processing time and event time are different scales. Reading one must not
  # be able to trip the other's guard, or a live clock at epoch 1.7e9 would
  # reject every real watermark.
  def test_the_two_sequences_are_guarded_independently
    clock = Stream::WallClock.new(now: 1_700_000_000)
    clock.now_processing

    assert_equal 42, clock.now_event(42), 'an event watermark is not a processing time'

    replay = Stream::ReplayClock.new(start: 100)
    replay.now_event(5)

    assert_equal 100, replay.now_processing
  end

  def test_replay_advance_refuses_a_negative_delta
    clock = Stream::ReplayClock.new(start: 100)
    assert_raises(Stream::StreamClockError) { clock.advance(-1) }
    assert_raises(Stream::StreamClockError) { clock.advance(1.5) }
    assert_equal 100, clock.now_processing
  end

  def test_a_wall_clock_cannot_be_advanced
    assert_raises(Stream::StreamClockError) { Stream::WallClock.new(now: 1).advance(5) }
  end

  # --- CognitionAdmission fails closed on absent evidence ------------------

  def spec(**overrides)
    Stream::SituationSpec.new(
      spec_id: 'temp.anomaly',
      schema_id: 'temperature.v2',
      risk_class: :r1_notify,
      debounce_seconds: 5,
      cooldown_seconds: 60,
      freshness_seconds: 600,
      deadline_seconds: 60,
      max_confidence: 0.9,
      max_cost_estimate: 100, **overrides
    )
  end

  def trigger(scores)
    { 'situation_version' => 1, 'cost_estimate' => 1, 'freshness' => 0, 'scores' => scores }
  end

  def test_admission_admits_a_score_under_the_ceiling
    outcome = Stream::CognitionAdmission.evaluate(trigger: trigger({ 'a' => 0.5 }), now: 0, spec: spec)

    assert_equal :admitted, outcome
  end

  def test_admission_rejects_a_score_over_the_ceiling
    outcome = Stream::CognitionAdmission.evaluate(trigger: trigger({ 'a' => 0.95 }), now: 0, spec: spec)

    assert_equal :rejected, outcome
  end

  # An empty score set used to score 0.0 and sail under the ceiling: an
  # admission gate admitting evidence-free input is the wrong direction to
  # fail.
  def test_admission_rejects_an_empty_score_set
    outcome = Stream::CognitionAdmission.evaluate(trigger: trigger({}), now: 0, spec: spec)

    assert_equal :rejected, outcome
  end
end
