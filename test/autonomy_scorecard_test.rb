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
    with_runtime(budgets: {"model_calls" => 2}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)

      rt.cli(%w[worker --once --json], factory: looping_factory)

      stops = rt.events.select { |event| event["event"] == "request.stopped" }
      assert_equal 1, stops.length, "expected a durable budget stop"
      assert_equal "budget_exhausted", stops.first.fetch("reason")
      assert_equal "model_calls", stops.first.fetch("budget")
      # The workspace is untouched: a run that hits its ceiling stops, it does
      # not half-finish.
      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt"))

      # Durable: visible to a separate process after the worker exited.
      assert_equal 1, rt.budget_exhaustions.length
      assert_hard_counters_zero(rt)
    end
  end

  # -------------------------------------------------------- 8. capabilities

  # A capability source exists for the agent only when the operator configured
  # it. Nothing in the repository, the model output, or a skill may add one.
  # Skills are the concrete source here because they are the sharpest version of
  # the rule: a skill body is INSTRUCTIONS the agent will follow, so a workspace
  # that could supply one would be granting itself authority in the most direct
  # way available. Memory, MCP and websearch are covered by their own cases as
  # they are wired.
  def test_case_08_capability_source_requires_operator_configuration
    with_runtime do |rt|
      # A checkout that ships its own skill, and asks to have it loaded.
      write_skill(File.join(rt.workspace, "skills"), "workspace-skill")
      File.write(File.join(rt.workspace, "tamoz.yaml"),
                 Psych.dump("sources" => {"skills" => {"enabled" => true,
                                                       "root" => File.join(rt.workspace, "skills")}}))
      rt.cli(%W[queue add --task Do\ the\ thing --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      refute_includes rt.capability_sources, "skills",
                      "repository content granted a capability source"
      assert_empty rt.capability_catalog.grep(/skill/),
                   "repository content put a skill capability on the catalog"

      # The same source, configured by the OPERATOR, from the operator's own
      # directory — and really there, not merely named in a config echo. The
      # catalog is what the agent can actually dispatch, which is the difference
      # between "configured" and "usable".
      write_skill(File.join(rt.dir, "skills"), "operator-skill")
      rt.enable_source("skills")
      rt.rewrite_profile_for_skills
      rt.cli(%W[queue add --task Do\ the\ thing --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      assert_includes rt.capability_sources, "skills",
                      "operator-configured source was not available"
      refute_empty rt.capability_catalog.grep(/skill/),
                   "operator-configured skills exposed no dispatchable capability"
      assert_hard_counters_zero(rt)
    end
  end

  # ------------------------------------------------- 10. unknown effects

  # An effect whose outcome is genuinely unknown is never retried by a machine.
  def test_case_10_unknown_effect_never_retries_automatically
    with_runtime(unattended: {"reconcilable" => %w[apply_patch]}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)

      # Killed at the one point where the effect's outcome cannot be proven.
      rt.cli(%w[worker --once --json], factory: crashing_factory(after: :effect_started))
      # The worker died before its receipt. A third party changed the target
      # before recovery, so neither the approved before-state nor after-state
      # proves what the effect did.
      File.write(File.join(rt.workspace, "note.txt"), "changed elsewhere\n")

      3.times { rt.cli(%w[worker --once --json], factory: edit_factory) }

      blocked = rt.blocked_effects
      assert_equal 1, blocked.length, "expected one blocked unknown effect"
      assert_equal "unknown", blocked.first.fetch("status")
      refute rt.events.any? { |event| event["event"] == "request.completed" },
             "an unknown effect must not be reported as completed"
      assert_equal(1, rt.events.count { |event| event["event"] == "request.blocked" })
      assert_equal 0, rt.counter("unknown_effect_retries"),
                   "a machine retried an unknown effect"
      assert_hard_counters_zero(rt)
    end
  end

  # ----------------------------------------------------- 11. channel turn

  # A chat message becomes a durable turn and the answer returns to the SAME
  # conversation (design §16 case 11).
  def test_case_11_chat_message_becomes_a_durable_turn_and_an_answer_returns
    with_runtime(channels: channel_map) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.client.updates = [message_update(1, "Read note.txt")]

      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)
      serve_once(rt, factory: read_only_factory)

      answers = rt.client.sent.select { |delivery| delivery.fetch("text") == "hello" }
      assert_equal 1, answers.length, "the terminal answer must be sent exactly once"
      assert_operator rt.client.sent.length, :>=, 2, "the accepted acknowledgement must precede the answer"
      assert_match(/\AAccepted\./, rt.client.sent.first.fetch("text"),
                   "the acknowledgement must be the first channel delivery")
      assert_equal "22222222", answers.first.fetch("chat_id"),
                   "the answer returns to the conversation that asked"
      # The VERIFIED answer and nothing else. Asserting `include?` here would
      # also pass on a dump of the session state that produced it, which is
      # internal detail and unbounded — a correspondent gets the answer.
      assert_equal "hello", answers.first.fetch("text"),
                   "the answer must be the turn's verified answer, not its state"
      assert_hard_counters_zero(rt)
    end
  end

  # ------------------------------------------------- 12. duplicate update

  # The same update_id twice (concurrently or across a restart) makes exactly
  # one logical turn (design §16 case 12, invariant 57's replay dedup).
  def test_case_12_the_same_update_never_makes_two_turns
    with_runtime(channels: channel_map) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.client.updates = [message_update(1, "Read note.txt"), message_update(1, "Read note.txt")]

      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)

      completions = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completions.length, "a duplicated update must make exactly one turn"
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------- 13. deny callback

  # An approval pause renders a prompt, the Deny press resolves the EXACT
  # interrupt set, and the same occurrence completes denied — nothing edited,
  # nothing answered for the human (design §16 case 13, ADR-043, invariant 58).
  def test_case_13_a_deny_press_denies_the_exact_interrupt_set
    with_runtime(channels: channel_map(approvals: {"mode" => "deny_only", "prompt_ttl_s" => 900}),
                 unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.client.updates = [message_update(1, "Fix note.txt")]

      serve_once(rt, factory: edit_factory)
      # The worker pauses on the edit interrupt; the prompt delivery is queued.
      worker_once(rt, factory: edit_factory)
      # The gateway sends the prompt (receipt durable -> prompt active).
      serve_once(rt, factory: edit_factory)

      buttons = rt.client.sent.last.dig("reply_markup", "inline_keyboard").first
      deny = buttons.find { |button| button.fetch("text") == "Deny" }
      refute_nil deny, "the prompt message must carry a Deny button"
      reference = deny.fetch("callback_data")
      refute_empty reference, "the Deny button must carry the single-use reference"
      rt.client.updates = [callback_update(2, reference)]

      # The Deny press resolves exactly one active prompt to a deny decision.
      serve_once(rt, factory: edit_factory)
      # The worker consumes the decision: the same occurrence completes denied.
      worker_once(rt, factory: edit_factory)

      denied = rt.events.select { |event| event["event"] == "request.denied" }
      assert_equal 1, denied.length, "the denied occurrence must emit one denied event"
      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "the denied interrupt must never edit the workspace"
      assert_empty rt.pending_approvals, "the decision must consume the pause"
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------- 14. unbound sender

  # An unbound sender is durably rejected: no turn, no answer, no workspace
  # content in the channel, zero unauthorized admissions (design §16 case 14,
  # invariant 56).
  def test_case_14_an_unbound_sender_never_reaches_a_turn
    with_runtime(channels: channel_map) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "secret content\n")
      rt.client.updates = [message_update(1, "Read note.txt", user_id: 999_999_99)]

      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)

      assert_empty rt.client.sent, "an unbound sender must receive nothing"
      assert_empty(rt.events.select { |event| event["event"] == "request.completed" })
      channels = rt.status_document.fetch("channels")
      assert_equal 0, channels.dig("safety_counters", "unauthorized_inbound_admissions"),
                   "a rejection is not an admission"
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------- 15. ambiguous send

  # A send whose receipt never arrives is `:unknown` — never silently retried,
  # never duplicated (design §16 case 15, §10 ambiguity policy).
  def test_case_15_an_ambiguous_send_becomes_unknown_and_is_never_resent
    with_runtime(channels: channel_map) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.client.updates = [message_update(1, "Read note.txt")]
      rt.client.ambiguous_sends = 1

      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)
      # The send times out on the wire: the delivery is :unknown, not retried.
      serve_once(rt, factory: read_only_factory)

      channels = rt.status_document.fetch("channels")
      assert_equal 1, channels.fetch("surfaces").first.fetch("unknown_deliveries"),
                   "the ambiguous send must be durably :unknown"
      sent = rt.client.sent.length
      serve_once(rt, factory: read_only_factory)
      assert_equal sent, rt.client.sent.length, "an :unknown delivery is never blindly resent"
      assert_hard_counters_zero(rt)
    end
  end

  # ---------------------------------------------------- 16. capacity gate

  # Capacity saturation refuses new intake while the reserved terminal answer
  # for an admitted request still appends, and the slots return when the turn
  # finishes (design §16 case 16, invariant 57).
  def test_case_16_saturated_capacity_refuses_intake_but_reserves_the_answer
    limits = {"outbox_capacity" => 3, "max_open_requests" => 1,
              "max_denial_prompts_per_request" => 1}
    with_runtime(channels: channel_map(limits:, approvals: {"mode" => "deny_only", "prompt_ttl_s" => 900},
                                       rendering: {"max_parts" => 1}),
                 unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      # One request's reservation (parts + denial prompts) fills the cap; a
      # second request must be refused while the first is still open.
      rt.client.updates = [message_update(1, "Read note.txt"), message_update(2, "Read note.txt")]

      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)

      completions = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completions.length, "saturated intake must refuse the second request"
      assert rt.client.sent.any? { |message| message.fetch("text").include?("capacity") },
             "the refused sender should get a busy notice, not a turn"

      # The reserved terminal answer appends (drain sends it once).
      serve_once(rt, factory: read_only_factory)
      assert rt.client.sent.any? { |message| message.fetch("text").include?("hello") },
             "the reserved terminal answer must be delivered"

      # The finished request released its slots: intake is open again.
      rt.client.updates = [message_update(3, "Read note.txt")]
      serve_once(rt, factory: read_only_factory)
      worker_once(rt, factory: read_only_factory)
      assert_equal(2, rt.events.count { |event| event["event"] == "request.completed" })
      assert_hard_counters_zero(rt)
    end
  end

  # ------------------------------------------------ 17. conversational turn

  # Rapid-fire messages are not dropped and not context-free: the follow-up
  # queues behind the running turn, is told so, and is planned with the
  # thread's transcript (design §16's channel case, conversational bar).
  def test_case_17_follow_up_messages_queue_and_carry_the_transcript
    with_runtime(channels: channel_map(limits: {"per_chat_messages_per_s" => 100.0})) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      model = ScriptedModel.new(
        plan: [plan_step("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      factory = ->(_options) { model }
      rt.client.updates = [message_update(1, "Read note.txt"),
                           message_update(2, "and what does it start with?")]

      serve_once(rt, factory:)
      worker_once(rt, factory:)
      serve_once(rt, factory:)

      answers = rt.client.sent.select { |delivery| delivery.fetch("text") == "hello" }
      assert_equal 2, answers.length, "every message must get a terminal answer"
      assert(rt.client.sent.any? { |delivery| delivery.fetch("text").include?("Queued behind earlier work") },
             "the follow-up must be told it queued, not that it started")
      refute rt.events.any? { |event| event["event"] == "request.failed" },
             "no message may be dropped"
      plan_prompts = model.calls.select { |call| call.fetch(:stage) == :plan }
                                .map { |call| call.fetch(:prompt) }
      assert(plan_prompts.any? { |prompt| prompt.include?('"conversation"') && prompt.include?("Read note.txt") },
             "the follow-up must be planned with the transcript")
      assert_hard_counters_zero(rt)
    end
  end

  # -------------------------------------- 18. approval pause without prompts

  # A turn parked on approval on a surface where approvals are DISABLED used
  # to go silent — and every message after it died at claim. Now the channel
  # hears why the work is waiting, follow-ups wait instead of dying, and the
  # thread resumes cleanly when the operator approves out of band.
  def test_case_18_an_approval_pause_without_prompts_notifies_and_never_strands
    with_runtime(channels: channel_map, unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.client.updates = [message_update(1, "Fix note.txt")]

      serve_once(rt, factory: edit_factory)
      worker_once(rt, factory: edit_factory)
      serve_once(rt, factory: edit_factory)

      assert(rt.client.sent.any? { |delivery| delivery.fetch("text").include?("approvals are not enabled") },
             "a parked turn on a surface without approvals must say why it waits")

      rt.client.updates = [message_update(2, "Read note.txt")]
      serve_once(rt, factory: edit_factory)
      worker_once(rt, factory: edit_factory)

      refute rt.events.any? { |event| event["event"] == "request.failed" },
             "a follow-up during an approval pause must wait, not die"

      approval = rt.pending_approvals.first.fetch("request_id")
      assert_equal 0, rt.cli(%W[approve #{approval} --json]), rt.err
      worker_once(rt, factory: read_only_factory)
      serve_once(rt, factory: read_only_factory)

      assert_equal "fixed\n", File.read(File.join(rt.workspace, "note.txt")),
                   "the approved occurrence must resume and edit"
      assert_equal(2, rt.events.count { |event| event["event"] == "request.completed" },
                   "both the approved turn and the queued follow-up must complete")
      assert_hard_counters_zero(rt)
    end
  end

  private

  # The channel cases drive the public CLI; these helpers keep the expected
  # exit code at the point of use.
  def serve_once(rt, factory: nil)
    status = rt.cli(%w[comms serve --once], factory:)
    assert_equal 0, status, rt.err
  end

  def worker_once(rt, factory: nil)
    status = rt.cli(%w[worker --once --json], factory:)
    assert_equal 0, status, rt.err
  end

  def channel_map(limits: nil, approvals: nil, rendering: nil)
    entry = {
      "kind" => "telegram", "revision" => 1, "enabled" => true,
      "profile" => "trusted",
      "credential_ref" => {"kind" => "env", "name" => "TAMOZ_TELEGRAM_BOT_TOKEN"},
      "expected_bot_id" => 7_463_512_990,
      "admission" => {"direct" => "allowlist", "correspondents" => ["telegram:user:11111111"]},
      "approvals" => {"mode" => "none", "prompt_ttl_s" => 900}
    }
    entry["approvals"] = approvals if approvals
    entry["limits"] = limits if limits
    entry["rendering"] = rendering if rendering
    {"telegram-ops" => entry}
  end

  def message_update(id, text, user_id: 111_111_11)
    {"update_id" => id,
     "message" => {"message_id" => id, "date" => 1_752_700_800,
                   "chat" => {"id" => 222_222_22, "type" => "private"},
                   "from" => {"id" => user_id}, "text" => text}}
  end

  def callback_update(id, reference)
    {"update_id" => id,
     "callback_query" => {"id" => "q-#{id}", "from" => {"id" => 111_111_11},
                          "message" => {"chat" => {"id" => 222_222_22, "type" => "private"}},
                          "data" => reference}}
  end
end
