# frozen_string_literal: true

# The autonomy scorecard.
#
# Every case here exercises the PUBLIC product surface — `Tamoz::Agent::CLI.run`
# — and nothing else. No test-only construction, no reaching into a library to
# build a session by hand. If a case passes, an operator can reproduce it from a
# shell; if it fails, the product does not have the behaviour, whatever the
# library tests say.
#
# The scorecard is the gate for the autonomy milestone. `script/autonomy_scorecard`
# runs this file and regenerates `docs/autonomy-scorecard.json` from the executed
# result, so a row reads `pass` only because its case ran and passed.
#
# Hard safety counters (unauthorized_effects, duplicate_effects,
# unknown_effect_retries, headless_auto_approvals) must be zero in every case.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AutonomyScorecardTest < Minitest::Test
  include AutonomyCase

  # ---------------------------------------------------------------- 1. trigger

  # A queued read-only task runs to completion with nobody watching. This is the
  # whole product in one line: something arrives, the worker picks it up, the
  # agent answers, the outcome is durable.
  def test_case_01_queued_read_only_task_completes_unattended
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")

      status = rt.cli(%W[queue add --task Read\ note.txt], factory: read_only_factory)
      assert_equal 0, status, "queue add failed: #{rt.err}"

      status = rt.cli(%w[worker --once --json], factory: read_only_factory)
      assert_equal 0, status, "worker failed: #{rt.err}"

      completions = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completions.length, "expected exactly one completion, got #{rt.events.length} events"
      assert_equal "completed", completions.first.fetch("status")
      assert_hard_counters_zero(rt)
    end
  end

  # ------------------------------------------------------------- 2. scheduling

  # An interval schedule that has been due once produces exactly one logical
  # occurrence — not one per poll.
  def test_case_02_interval_schedule_produces_exactly_one_occurrence
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")

      status = rt.cli(%W[schedule add --id nightly --interval 3600 --task Read\ note.txt],
                      factory: read_only_factory)
      assert_equal 0, status, "schedule add failed: #{rt.err}"

      # Three polls across the same interval window. Only the first instant is
      # due, so only one occurrence may ever exist.
      3.times { rt.cli(%w[worker --once --json], factory: read_only_factory) }

      occurrences = rt.occurrences("nightly")
      assert_equal 1, occurrences.length,
                   "interval schedule produced #{occurrences.length} occurrences across three polls"
      assert_hard_counters_zero(rt)
    end
  end

  # --------------------------------------------------------- 3. crash recovery

  # The worker dies after claiming work and before finishing it. A second worker
  # takes over the SAME occurrence and the effect happens once.
  def test_case_03_worker_death_after_claim_resumes_without_duplicate
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt], factory: read_only_factory)

      # Crash mid-turn, after the claim is durable.
      rt.cli(%w[worker --once --json], factory: crashing_factory(after: :claim))

      status = rt.cli(%w[worker --once --json], factory: read_only_factory)
      assert_equal 0, status, "recovery worker failed: #{rt.err}"

      completions = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completions.length, "duplicate execution after crash"
      assert_equal 0, rt.counter("duplicate_effects")
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------------- 4/5. authority

  # A workspace edit the trusted profile explicitly preauthorized as a
  # reconcilable effect completes with no human present.
  def test_case_04_preauthorized_reconcilable_edit_completes_unattended
    with_runtime(unattended: {"reconcilable" => %w[apply_patch]}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)

      status = rt.cli(%w[worker --once --json], factory: edit_factory)
      assert_equal 0, status, "worker failed: #{rt.err}"

      assert_equal "fixed\n", File.read(File.join(rt.workspace, "note.txt"))
      assert_hard_counters_zero(rt)
    end
  end

  # The same edit, NOT preauthorized, must stop before it mutates anything and
  # ask for a human. The file on disk is the proof.
  def test_case_05_unauthorized_edit_pauses_before_mutation
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "unauthorized edit mutated the workspace before pausing"
      pauses = rt.events.select { |event| event["event"] == "request.paused" }
      assert_equal 1, pauses.length, "expected a durable pause, got: #{rt.events.map { _1["event"] }}"
      assert_equal "approval_required", pauses.first.fetch("reason")
      assert_equal 0, rt.counter("unauthorized_effects")
      assert_equal 0, rt.counter("headless_auto_approvals")
    end
  end

  # Granting the approval resumes the SAME occurrence rather than starting a new
  # one, and only then does the effect land.
  def test_case_06_approval_resumes_the_same_occurrence
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      pending = rt.pending_approvals
      assert_equal 1, pending.length, "expected one paused approval"
      occurrence = pending.first.fetch("request_id")

      status = rt.cli(%W[approve #{occurrence} --json], factory: edit_factory)
      assert_equal 0, status, "approve failed: #{rt.err}"

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "fixed\n", File.read(File.join(rt.workspace, "note.txt"))
      completions = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completions.length
      assert_equal occurrence, completions.first.fetch("request_id"),
                   "approval started a new occurrence instead of resuming the paused one"
      assert_hard_counters_zero(rt)
    end
  end

  # ------------------------------------------------------------- 7. budgets

  # A budget the agent cannot widen stops the run durably and visibly.
  def test_case_07_exhausted_budget_stops_durably
    with_runtime(budgets: {"max_model_calls" => 2}) do |rt|
      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)

      rt.cli(%w[worker --once --json], factory: looping_factory)

      stops = rt.events.select { |event| event["event"] == "request.stopped" }
      assert_equal 1, stops.length, "expected a durable budget stop"
      assert_equal "budget_exhausted", stops.first.fetch("reason")
      assert_equal "max_model_calls", stops.first.fetch("budget")

      # Durable: visible to a separate process after the worker exited.
      assert_equal 1, rt.budget_exhaustions.length
      assert_hard_counters_zero(rt)
    end
  end

  # -------------------------------------------------------- 8. capabilities

  # A capability source exists for the agent only when the operator configured
  # it. Nothing in the repository, the model output, or a skill may add one.
  def test_case_08_capability_source_requires_operator_configuration
    with_runtime do |rt|
      # Repository content that asks for websearch must not produce websearch.
      File.write(File.join(rt.workspace, "tamoz.yaml"),
                 Psych.dump("sources" => {"websearch" => {"enabled" => true}}))
      rt.cli(%W[queue add --task Research\ this --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      refute_includes rt.capability_sources, "websearch",
                      "repository content granted a capability source"
      assert_empty rt.capability_catalog.grep(/search/),
                   "repository content put a searchable capability on the catalog"

      # The same source, configured by the operator, is present — and is really
      # there, not merely named in a config echo. The catalog is what the agent
      # can actually dispatch, so asserting on it is the difference between
      # "configured" and "usable".
      rt.enable_source("websearch")
      rt.cli(%W[queue add --task Research\ this --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      assert_includes rt.capability_sources, "websearch",
                      "operator-configured source was not available"
      refute_empty rt.capability_catalog.grep(/search/),
                   "operator-configured websearch exposed no dispatchable capability"
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------- 9. bounded input

  # A producer faster than the consumer cannot grow the queue or the spool
  # without bound. Saturation is evidence, not silence.
  def test_case_09_fast_producer_stays_within_enforced_bounds
    with_runtime(stream: {"max_queue_depth" => 8, "max_spool_bytes" => 4096}) do |rt|
      rt.publish_burst(count: 200, bytes: 512)

      assert_operator rt.queue_depth, :<=, 8, "queue depth exceeded its configured bound"
      assert_operator rt.spool_bytes, :<=, 4096, "spool exceeded its configured byte bound"
      assert_operator rt.counter("stream_rejected"), :>, 0,
                      "producer outran the bound with no rejection evidence"
      assert_hard_counters_zero(rt)
    end
  end

  # -------------------------------------------------- 10. unknown effects

  # An effect whose outcome is genuinely unknown is never retried by a machine.
  def test_case_10_unknown_effect_never_retries_automatically
    with_runtime(unattended: {"reconcilable" => %w[apply_patch]}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)

      # Killed at the one point where the effect's outcome cannot be proven.
      rt.cli(%w[worker --once --json], factory: crashing_factory(after: :effect_started))

      3.times { rt.cli(%w[worker --once --json], factory: edit_factory) }

      blocked = rt.blocked_effects
      assert_equal 1, blocked.length, "expected one blocked unknown effect"
      assert_equal "unknown", blocked.first.fetch("status")
      assert_equal 0, rt.counter("unknown_effect_retries"),
                   "a machine retried an unknown effect"
      assert_hard_counters_zero(rt)
    end
  end
end
