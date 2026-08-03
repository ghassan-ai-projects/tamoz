# frozen_string_literal: true

require_relative "test_helper"
require_relative "stream_interlock_harness"

# P14-P/C2/C6 — the action boundary: post-approval revalidation, read-only
# interlock with the narrowest-point re-read (TOCTOU), simulator-only
# dispatch, R4 advisory never dispatched, and the dependency-direction test
# proving production code cannot see the mutable harness or any write API.
class StreamActionBoundaryTest < Minitest::Test
  Stream = Tamoz::Stream

  def accepting_revalidate
    ->(_intent) { true }
  end

  def test_dependency_direction_production_cannot_see_the_mutable_harness
    # The production lib directory must not reference the harness (it lives in
    # the test tree) or any write API. Grep every production tamoz-stream file
    # for the harness name and for mutation verbs on the interlock.
    production_files = Dir[File.expand_path("../gems/tamoz-stream/lib/**/*.rb", __dir__)]
    assert_operator production_files.length, :>=, 10
    production_files.each do |path|
      content = File.read(path)
      refute_includes content, "MutableInterlockHarness",
                       "production code must not reference the test-tree harness"
      refute_includes content, "trip!",
                       "production code must not mutate an interlock"
      refute_includes content, "arm!",
                       "production code must not arm an interlock"
    end
  end

  def test_revalidation_and_interlock_gate_delivery
    harness = MutableInterlockHarness.new
    intent = {"risk" => "r2_bounded", "target" => "simulator-1"}

    # Fresh snapshot + revalidation pass + interlock ready -> deliver.
    result = Stream::ActionBoundary.revalidate_and_check(
      intent:,
      snapshot_digest: "sha256:s1",
      current_snapshot_digest: "sha256:s1",
      revalidate: accepting_revalidate,
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r2_bounded
    )
    assert_equal true, result.fetch("deliver")

    # Superseded snapshot -> refused (late Decision dies).
    stale = Stream::ActionBoundary.revalidate_and_check(
      intent:,
      snapshot_digest: "sha256:old",
      current_snapshot_digest: "sha256:new",
      revalidate: accepting_revalidate,
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r2_bounded
    )
    assert_equal false, stale.fetch("deliver")
    assert_equal "snapshot_superseded", stale.fetch("reason")

    # Revalidation failure -> refused (approval does not freeze reality).
    denied = Stream::ActionBoundary.revalidate_and_check(
      intent:,
      snapshot_digest: "sha256:s1",
      current_snapshot_digest: "sha256:s1",
      revalidate: ->(_intent) { false },
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r2_bounded
    )
    assert_equal false, denied.fetch("deliver")
    assert_equal "revalidation_failed", denied.fetch("reason")

    # R4 advisory is NEVER dispatched.
    advisory = Stream::ActionBoundary.revalidate_and_check(
      intent:, snapshot_digest: "sha256:s1",
      current_snapshot_digest: "sha256:s1",
      revalidate: accepting_revalidate,
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r4_advisory
    )
    assert_equal false, advisory.fetch("deliver")
    assert_equal "r4_advisory_never_dispatched", advisory.fetch("reason")
  end

  def test_interlock_trip_fails_closed_and_toctou_is_closed_both_sides
    harness = MutableInterlockHarness.new
    harness.trip!("interlock-1")
    intent = {"risk" => "r2_bounded", "target" => "simulator-1"}

    # Tripped interlock -> refused, never dispatched.
    tripped = Stream::ActionBoundary.revalidate_and_check(
      intent:,
      snapshot_digest: "sha256:s1",
      current_snapshot_digest: "sha256:s1",
      revalidate: accepting_revalidate,
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r2_bounded
    )
    assert_equal false, tripped.fetch("deliver")
    assert_equal "interlock_not_ready", tripped.fetch("reason")

    # TOCTOU: the boundary checked ready, then the interlock trips between the
    # check and delivery. The simulator asserts ready at delivery and rejects
    # a Command delivered after the interlock tripped (C6).
    harness.arm!("interlock-1")
    result = Stream::ActionBoundary.revalidate_and_check(
      intent:,
      snapshot_digest: "sha256:s1",
      current_snapshot_digest: "sha256:s1",
      revalidate: accepting_revalidate,
      interlock: harness, interlock_id: "interlock-1",
      risk_class: :r2_bounded
    )
    assert_equal true, result.fetch("deliver")
    harness.trip!("interlock-1") # tripped AFTER the boundary check
    error = assert_raises(Stream::InterlockUnavailableError) do
      Stream::ActionBoundary.simulator_accepts(
        command: result.fetch("command"), interlock: harness, interlock_id: "interlock-1"
      )
    end
    assert_includes error.message, "interlock tripped"
  end

  def test_interlock_read_failure_fails_closed
    broken = Object.new
    def broken.ready?(_id) = raise Stream::InterlockUnavailableError, "sensor offline"
    def broken.state(_id) = raise Stream::InterlockUnavailableError, "sensor offline"

    # An interlock read failure FAILS CLOSED with the typed error (design
    # §10): no dispatch ever happens.
    error = assert_raises(Stream::InterlockUnavailableError) do
      Stream::ActionBoundary.revalidate_and_check(
        intent: {"risk" => "r2_bounded"},
        snapshot_digest: "sha256:s1",
        current_snapshot_digest: "sha256:s1",
        revalidate: accepting_revalidate,
        interlock: broken, interlock_id: "interlock-1",
        risk_class: :r2_bounded
      )
    end
    assert_includes error.message, "no dispatch"
  end
end
