# frozen_string_literal: true

# The unattended contract, attacked from every direction (redesign plan §7):
# headless is not consent; a denial is terminal for the effect; policy data
# lives in the operator config, never in workspace content; an expired ask
# resolves to the profile's on_timeout outcome; and an approval answers one
# occurrence only.
#
# The scorecard proves the happy paths: gated work pauses, approval resumes.
# This file tries to break the rule.
require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentUnattendedPolicyTest < Minitest::Test
  include AutonomyCase

  # The whole point: headless is not consent.
  def test_a_worker_left_running_never_grants_its_own_approval
    with_runtime(approval_profile: "review") do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)

      # Many passes, no human, plenty of opportunity to give in.
      5.times { rt.cli(%w[worker --once --json], factory: edit_factory) }

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt"))
      assert_equal 1, rt.pending_approvals.length,
                   "the approval should still be waiting after five passes"
      assert_equal 0, rt.counter("headless_auto_approvals")
      assert_equal 0, rt.counter("unauthorized_effects")
    end
  end

  # A denial is a decision too, and it must stop the work rather than leaving it
  # to be re-asked forever.
  def test_a_denied_approval_stops_without_mutating
    with_runtime(approval_profile: "review") do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      request_id = rt.pending_approvals.first.fetch("request_id")
      assert_equal 0, rt.cli(%W[approve #{request_id} --deny --json]), rt.err
      assert_equal "denied", JSON.parse(rt.out).fetch("decision")

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "a denied approval still mutated the workspace"
      denials = rt.events.select { |event| event["event"] == "request.denied" }
      assert_equal 1, denials.length
      assert_equal 0, rt.counter("unauthorized_effects")
    end
  end

  # The workspace is the thing the agent edits. It must never be the thing that
  # decides what the agent may edit: policy data loads from the operator config
  # only, and a workspace path is not a policy source.
  def test_workspace_content_cannot_preauthorize_itself
    with_runtime(approval_profile: "review") do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      File.write(File.join(rt.workspace, ".tamoz.yaml"), Psych.dump(
        "unattended" => {"reconcilable" => %w[apply_patch create_file]}
      ))
      FileUtils.mkdir_p(File.join(rt.workspace, "profiles"))
      File.write(File.join(rt.workspace, "profiles", "trusted.yaml"), Psych.dump(
        "profile" => {"name" => "trusted", "tier_defaults" => {"workspace_write" => "allow"}}
      ))

      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "repository content preauthorized an unattended mutation"
      assert_equal 1, rt.pending_approvals.length

      # Pointing the session at the workspace file as a policy source is refused.
      status = rt.cli(
        %W[--approval-profile #{File.join(rt.workspace, 'profiles', 'trusted.yaml')} queue add --task x --profile trusted],
        factory: edit_factory
      )
      refute_equal 0, status, "a workspace file must not load as approval policy"
    end
  end

  # Approving something that is not waiting must not create a standing
  # permission that a later pause silently consumes.
  def test_approving_an_unknown_request_is_refused
    with_runtime(approval_profile: "review") do |rt|
      assert_equal 1, rt.cli(%W[approve #{SecureRandom.uuid} --json])
      assert_match(/no paused approval/, rt.err)

      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt"))
      assert_equal 1, rt.pending_approvals.length
    end
  end

  # An approval answers ONE occurrence. It must not carry over to the next piece
  # of work on the same thread.
  def test_an_approval_does_not_carry_to_the_next_occurrence
    with_runtime(approval_profile: "review") do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted --thread work],
             factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)
      first = rt.pending_approvals.first.fetch("request_id")
      rt.cli(%W[approve #{first} --json])
      rt.cli(%w[worker --once --json], factory: edit_factory)
      assert_equal "fixed\n", File.read(File.join(rt.workspace, "note.txt"))

      # A second edit on the same thread must ask again.
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted --thread work],
             factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "an approval carried over to a later occurrence"
      pending = rt.pending_approvals
      assert_equal 1, pending.length
      refute_equal first, pending.first.fetch("request_id")
    end
  end

  # The unattended profile exists so expiry DENIES instead of parking forever:
  # nobody is watching, so the worker applies the outcome itself and the turn
  # continues with a structured denial.
  def test_an_expired_ask_resolves_to_the_profiles_deny_outcome
    with_runtime(approval_ask: {timeout_s: 1, on_timeout: "deny"}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)
      assert_equal 1, rt.pending_approvals.length, "the ask must park first"

      sleep 1.5
      if ENV['TAMOZ_DEBUG']
        warn('DIAG ev=' + rt.events.map { |e| [e['event'], e['reason']].compact.join(':') }.inspect)
        warn('DIAG err=' + rt.err[0, 400])
      end
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "the timed-out effect must not run"
      assert_empty rt.pending_approvals,
                   "expiry must resolve the ask, not leave it parked"
      assert_equal 1, rt.events.count { |event| event["event"] == "request.denied" }
    end
  end
end
