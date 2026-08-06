# frozen_string_literal: true

# The trusted unattended policy, attacked from every direction it can be
# attacked from.
#
# The scorecard proves the happy paths: preauthorized work runs, unauthorized
# work pauses, approval resumes. This file tries to break the rule — by having
# repository content claim authority, by denying an approval, by removing the
# human entirely, and by pointing a profile at tools it does not allow.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentUnattendedPolicyTest < Minitest::Test
  include AutonomyCase

  # The whole point: headless is not consent.
  def test_a_worker_left_running_never_grants_its_own_approval
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
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
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
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
  # decides what the agent may edit.
  def test_workspace_content_cannot_preauthorize_itself
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      # Every shape of "please trust me" a checkout could try.
      File.write(File.join(rt.workspace, ".tamoz.yaml"), Psych.dump(
        "unattended" => {"reconcilable" => %w[apply_patch create_file]}
      ))
      File.write(File.join(rt.workspace, "trusted.yaml"), Psych.dump(
        "profile" => {"schema_version" => 1, "profile_id" => "trusted"},
        "unattended" => {"reconcilable" => %w[apply_patch]}
      ))
      FileUtils.mkdir_p(File.join(rt.workspace, "profiles"))
      File.write(File.join(rt.workspace, "profiles", "trusted.yaml"), Psych.dump(
        "unattended" => {"reconcilable" => %w[apply_patch]}
      ))

      rt.cli(%W[queue add --task Fix\ note.txt --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, "note.txt")),
                   "repository content preauthorized an unattended mutation"
      assert_equal 1, rt.pending_approvals.length
    end
  end

  # `forbidden` is not one list among equals — it wins.
  def test_forbidden_cannot_be_overridden_by_another_list
    Dir.mktmpdir("tamoz-forbidden") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(directory, "profile.yaml")
      tools = READ_ONLY_TOOLS + %w[apply_patch]
      File.write(path, Psych.dump(
        "profile" => {"schema_version" => 1, "profile_id" => "p", "profile_version" => "1.0",
                      "canonical_root" => workspace},
        "roots" => {"workspace" => workspace},
        "tools" => {"allowed" => tools, "approval_required" => []},
        "policy" => {"allow_changes" => true, "default_check_safety" => "read_only",
                     "graph_version" => "1", "behavior_version" => "1.0",
                     "tool_catalog_digest" => Tamoz::Agent::Toolbox.new(
                       root: workspace, allow_changes: true, checks: {},
                       allowed_tools: tools, approval_required: []
                     ).catalog_digest},
        # The same tool named as both preauthorized and forbidden.
        "unattended" => {"reconcilable" => %w[apply_patch], "forbidden" => %w[apply_patch]}
      ))
      File.chmod(0o600, path)

      profile = Tamoz::Agent::Profile.preview(path)

      refute_includes profile.unattended_preauthorized, "apply_patch",
                      "a forbidden tool was preauthorized by also listing it as reconcilable"
      assert_includes profile.unattended_requires_approval, "apply_patch"
    end
  end

  # A profile that preauthorizes something it does not allow is incoherent, and
  # silently ignoring the contradiction would make it look more permissive than
  # it is.
  def test_unattended_cannot_name_a_tool_the_profile_does_not_allow
    Dir.mktmpdir("tamoz-incoherent") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(directory, "profile.yaml")
      File.write(path, Psych.dump(
        "profile" => {"schema_version" => 1, "profile_id" => "p", "profile_version" => "1.0",
                      "canonical_root" => workspace},
        "roots" => {"workspace" => workspace},
        "tools" => {"allowed" => READ_ONLY_TOOLS, "approval_required" => []},
        "policy" => {"allow_changes" => false, "default_check_safety" => "read_only",
                     "graph_version" => "1", "behavior_version" => "1.0",
                     "tool_catalog_digest" => "sha256:#{"0" * 64}"},
        "unattended" => {"reconcilable" => %w[apply_patch]}
      ))
      File.chmod(0o600, path)

      error = assert_raises(Tamoz::Agent::Profile::ValidationError) do
        Tamoz::Agent::Profile.preview(path)
      end
      assert_match(/tools.allowed does not permit/, error.message)
    end
  end

  # A profile with no `unattended` section has never thought about running
  # without a human, so it authorizes nothing beyond reading.
  def test_a_profile_without_an_unattended_section_preauthorizes_nothing
    Dir.mktmpdir("tamoz-silent") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(directory, "profile.yaml")
      tools = READ_ONLY_TOOLS + %w[apply_patch]
      File.write(path, Psych.dump(
        "profile" => {"schema_version" => 1, "profile_id" => "p", "profile_version" => "1.0",
                      "canonical_root" => workspace},
        "roots" => {"workspace" => workspace},
        "tools" => {"allowed" => tools, "approval_required" => []},
        "policy" => {"allow_changes" => true, "default_check_safety" => "read_only",
                     "graph_version" => "1", "behavior_version" => "1.0",
                     "tool_catalog_digest" => "sha256:#{"0" * 64}"}
      ))
      File.chmod(0o600, path)

      profile = Tamoz::Agent::Profile.preview(path)

      assert_empty profile.unattended_preauthorized
      assert_equal tools.sort, profile.unattended_requires_approval.sort
    end
  end

  # Approving something that is not waiting must not create a standing
  # permission that a later pause silently consumes.
  def test_approving_an_unknown_request_is_refused
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
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
    with_runtime(unattended: {"reconcilable" => []}) do |rt|
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
end
