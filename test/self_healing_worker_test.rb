# frozen_string_literal: true

require_relative "test_helper"

# The durable path (worker) that Telegram and every queued/scheduled turn ride:
# a failed turn emits a `healing.assessment` operator event, classified from the
# turn's own observations. Executes nothing; correspondents are unaffected.
class SelfHealingWorkerTest < Minitest::Test
  ViewDouble = Data.define(:state)

  def worker_with(emitter)
    Tamoz::Agent::Worker.new(
      runtime: Object.new, session_builder: ->(_thread) {}, emitter:
    )
  end

  def emitted(events, type)
    events.find { |document| document["event"] == type }
  end

  def test_failed_turn_with_a_failed_check_emits_a_healing_assessment
    events = []
    worker = worker_with(->(document) { events << document })
    view = ViewDouble.new(state: {observations: [
      {"tool" => "run_check", "check" => {"name" => "values", "outcome" => "exit_1", "passed" => false}}
    ]})

    worker.send(:emit_healing_assessment, view, "thread-1", "occ-1")

    event = emitted(events, "healing.assessment")
    refute_nil event, "a failed durable turn must emit a healing assessment"
    assert_equal "verification_failed", event.fetch("assessment").fetch("category")
    assert_equal "escalated", event.fetch("assessment").fetch("route")
    assert_equal "thread-1", event.fetch("thread")
  end

  def test_a_clean_turn_emits_no_assessment
    events = []
    worker = worker_with(->(document) { events << document })
    view = ViewDouble.new(state: {observations: [{"tool" => "read_file", "output" => "ok"}]})

    worker.send(:emit_healing_assessment, view, "thread-1", "occ-1")

    assert_nil emitted(events, "healing.assessment")
  end
end
