# frozen_string_literal: true

# Runtime budgets, attacked where they would actually fail.
#
# The scorecard proves a spent budget stops the run. What matters as much is the
# other direction: that a budget cannot be widened from inside the run, that a
# profile which never asked for a ceiling does not acquire one, and that the stop
# survives the worker exiting.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentBudgetTest < Minitest::Test
  include AutonomyCase

  def test_a_budget_stop_is_durable_after_the_worker_exits
    with_runtime(budgets: {"model_calls" => 2}) do |rt|
      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)
      rt.cli(%w[worker --once --json], factory: looping_factory)

      # A separate process, reading only durable state.
      exhaustions = rt.budget_exhaustions

      assert_equal 1, exhaustions.length, "the budget stop did not survive the worker"
      assert_equal "model_calls", exhaustions.first.fetch("budget")
      refute_nil exhaustions.first["stopped_at"]
    end
  end

  # The budget lives in the operator's profile. Nothing the run produces — not a
  # task, not model output, not a workspace file — may raise it.
  def test_the_workspace_cannot_widen_a_budget
    with_runtime(budgets: {"model_calls" => 2}) do |rt|
      File.write(File.join(rt.workspace, "budgets.yaml"),
                 Psych.dump("budgets" => {"model_calls" => 10_000}))
      File.write(File.join(rt.workspace, "tamoz.yaml"),
                 Psych.dump("budgets" => {"model_calls" => 10_000}))

      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)
      rt.cli(%w[worker --once --json], factory: looping_factory)

      stops = rt.events.select { |event| event["event"] == "request.stopped" }
      assert_equal 1, stops.length, "workspace content widened the budget"
      assert_equal "model_calls", stops.first.fetch("budget")
    end
  end

  # Repeated polls must not let a stopped occurrence quietly resume and spend
  # more: the ceiling holds across passes, not just the one that hit it.
  def test_a_stopped_occurrence_does_not_resume_on_the_next_poll
    with_runtime(budgets: {"model_calls" => 2}) do |rt|
      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)
      4.times { rt.cli(%w[worker --once --json], factory: looping_factory) }

      stops = rt.events.select { |event| event["event"] == "request.stopped" }
      assert_equal 1, stops.length,
                   "a budget-stopped occurrence was retried across polls"
      assert_equal 1, rt.budget_exhaustions.length
    end
  end

  # A profile with no budgets keeps the pre-existing behaviour exactly. Enforcing
  # a default nobody asked for would be its own kind of surprise.
  def test_a_profile_without_budgets_is_not_given_one
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      assert_empty rt.events.select { |event| event["event"] == "request.stopped" }
      assert_empty rt.budget_exhaustions
      assert_equal 1, rt.events.count { |event| event["event"] == "request.completed" }
    end
  end

  # A budget large enough for the work must not fire — an off-by-one here would
  # make every long task look like an overrun.
  def test_a_budget_the_work_fits_inside_does_not_fire
    with_runtime(budgets: {"model_calls" => 50}) do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt --profile trusted], factory: read_only_factory)
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      assert_empty rt.events.select { |event| event["event"] == "request.stopped" }
      assert_equal 1, rt.events.count { |event| event["event"] == "request.completed" }
    end
  end

  def test_status_reports_budget_exhaustions_for_an_operator
    with_runtime(budgets: {"model_calls" => 2}) do |rt|
      rt.cli(%W[queue add --task Loop\ forever --profile trusted], factory: looping_factory)
      rt.cli(%w[worker --once --json], factory: looping_factory)

      rt.cli(%w[status --json])
      document = JSON.parse(rt.out)

      assert_equal 1, document.fetch("budget_exhaustions").length
      assert_equal "model_calls", document.dig("budget_exhaustions", 0, "budget")
    end
  end

  # An unknown budget key is a typo, and a typo that silently does nothing is a
  # ceiling the operator believes in and does not have.
  def test_an_unknown_budget_key_is_refused
    Dir.mktmpdir("tamoz-budget") do |directory|
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
        "budgets" => {"maximum_model_calls" => 5}
      ))
      File.chmod(0o600, path)

      error = assert_raises(Tamoz::Agent::Profile::ValidationError) do
        Tamoz::Agent::Profile.preview(path)
      end
      assert_match(/unknown budget fields/, error.message)
    end
  end
end
