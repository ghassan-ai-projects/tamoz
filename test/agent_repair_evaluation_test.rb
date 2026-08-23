# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class AgentRepairEvaluationTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(plan:, review:, verify:)
      @responses = {plan:, review:, verify:}.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      @responses.fetch(stage).shift || raise("missing #{stage} response")
    end
  end

  def test_failed_check_becomes_evidence_for_a_reviewed_repair_that_passes
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(from: 40, to: 41, check: "answer"),
          action_plan(from: 41, to: 42, check: "answer2")
        ],
        reviews: 3,
        final_satisfied: true
      )
      asks = []
      events = []

      result = runtime(
        root,
        model,
        asks:,
        checks: answer_checks("answer", "answer2")
      ).run("Make Broken.answer equal 42") { |event| events << event }

      assert result.satisfied
      assert_equal 42, load_value(root)
      assert_equal %w[run_check run_check], ask_tools(asks)
      repair_attempts = events.filter_map do |event|
        event.data["repair_attempt"] if event.type == :plan_accepted && %w[action repair].include?(event.data["phase"])
      end
      assert_equal [0, 1], repair_attempts
      repair_prompt = model.calls.select { |entry| entry.fetch(:stage) == :plan }.last.fetch(:prompt)
      assert_includes repair_prompt, "wrong answer 41"
      assert_includes repair_prompt, Digest::SHA256.hexdigest(value_source(41))
      assert_includes repair_prompt, "prior_action_reviews"
      assert events.any? { |event| event.type == :repair_started }
      refute events.any? { |event| event.type == :repair_stopped }
    end
  end

  def test_identical_repair_action_stops_before_new_approval_or_execution
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      repeated = action_plan(from: 40, to: 41)
      model = scripted_model(
        plans: [discovery_plan, repeated, repeated],
        reviews: 3,
        final_satisfied: true
      )
      asks = []
      events = []

      result = runtime(root, model, asks:).run("Make Broken.answer equal 42") do |event|
        events << event
      end

      refute result.satisfied
      assert_equal 41, load_value(root)
      assert_equal %w[run_check], ask_tools(asks)
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repeated_action", stopped.data.fetch("reason")
      assert_includes result.evidence.last, "repeated_action"
    end
  end

  def test_identical_failure_after_a_different_patch_stops_the_loop
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(from: 40, to: 41),
          action_plan_with_trailing_check(from: 41, to: 43, check: "answer", trailing_check: "answer2")
        ],
        reviews: 3,
        final_satisfied: true,
        fixed_failure: true
      )
      asks = []
      events = []

      result = runtime(
        root,
        model,
        asks:,
        fixed_failure: true,
        checks: answer_checks("answer", "answer2", failure: "same failure")
      ).run("Make Broken.answer equal 42") { |event| events << event }

      refute result.satisfied
      assert_equal 43, load_value(root)
      # A :once grant covers a single execution, so the repair attempt's check
      # asks again before failing with the same signature.
      assert_equal %w[run_check run_check], ask_tools(asks)
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repeated_failure", stopped.data.fetch("reason")
      assert_equal 1, stopped.data.fetch("repair_attempt")
    end
  end

  def test_distinct_failures_stop_after_the_maximum_repair_attempts
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(from: 40, to: 41, check: "answer"),
          action_plan(from: 41, to: 43, check: "answer2"),
          action_plan(from: 43, to: 44, check: "answer3")
        ],
        reviews: 4,
        final_satisfied: true
      )
      asks = []
      events = []

      result = runtime(
        root,
        model,
        asks:,
        checks: answer_checks("answer", "answer2", "answer3")
      ).run("Make Broken.answer equal 42") { |event| events << event }

      refute result.satisfied
      assert_equal 44, load_value(root)
      # Every distinct check name is a new governed step: one operator ask each.
      assert_equal %w[run_check run_check run_check], ask_tools(asks)
      assert_equal 3, events.count { |event| event.type == :approval_requested && event.data["tool"] == "run_check" }
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repair_attempts_exhausted", stopped.data.fetch("reason")
      assert_equal 2, stopped.data.fetch("repair_attempt")
    end
  end

  def test_denied_check_is_a_structured_result_and_preserves_the_approved_state
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(from: 40, to: 41, check: "answer"),
          action_plan(from: 40, to: 41, check: "answer")
        ],
        reviews: 3,
        final_satisfied: false
      )
      asks = []
      events = []

      result = build_runtime(root, model, ask: lambda do |**request|
        asks << request
        "deny"
      end).run("Make Broken.answer equal 42") { |event| events << event }

      refute result.satisfied
      denials = result.observations.select do |entry|
        entry.dig("failure", "error_class") == "ToolPolicyError"
      end
      assert_equal 1, denials.length
      assert_includes denials.first.fetch("failure").fetch("reason"), "denied by operator"
      # The turn continues after the denial; the repeated repair plan is what
      # stops the loop, and the workspace keeps its last approved state.
      assert_equal 41, load_value(root)
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repeated_action", stopped.data.fetch("reason")
      assert_includes result.evidence.last, "repeated_action"
    end
  end

  def test_failure_signatures_ignore_ansi_and_trailing_whitespace
    first = Tamoz::Agent::CheckReceipt.new(
      name: "test",
      outcome: "exit_1",
      stdout: "\e[31mfailed\e[0m  \r\n",
      stderr: "detail\n"
    )
    second = Tamoz::Agent::CheckReceipt.new(
      name: "test",
      outcome: "exit_1",
      stdout: "failed\n",
      stderr: "detail   \n\n"
    )

    assert_equal first.failure_signature, second.failure_signature
  end

  def test_timeout_is_structured_terminal_evidence_and_does_not_repeat_the_same_check
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      check_only = plan(
        step(id: "slow-check", tool: "run_check", arguments: {"name" => "answer"})
      )
      model = scripted_model(
        plans: [discovery_plan, check_only, check_only],
        reviews: 3,
        final_satisfied: true
      )
      asks = []
      events = []
      runtime = Tamoz::Agent.build(
        model:,
        root:,
        allow_changes: true,
        checks: {"answer" => [RbConfig.ruby, "-e", "sleep 2"]},
        check_timeout: 0.05,
        ask: lambda do |**request|
          asks << request
          "approve"
        end
      )

      result = runtime.run("Run the bounded answer check") { |event| events << event }

      refute result.satisfied
      check = result.observations.fetch(1).fetch("check")
      assert_equal "timed_out", check.fetch("outcome")
      refute check.fetch("passed")
      assert_match(/\A[0-9a-f]{64}\z/, check.fetch("failure_signature"))
      assert_equal ["run_check"], ask_tools(asks)
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repeated_action", stopped.data.fetch("reason")
      assert_includes result.evidence.last, "repeated_action"
    end
  end

  def test_action_structure_requires_a_check_after_the_last_patch
    Dir.mktmpdir("tamoz-repair-eval") do |root|
      write_value(root, 40)
      patch = action_plan(from: 40, to: 42).fetch("steps").first
      check = action_plan(from: 40, to: 42).fetch("steps").last
      model = scripted_model(
        plans: [
          discovery_plan,
          plan(patch),
          plan(check, patch),
          action_plan(from: 40, to: 42)
        ],
        reviews: 2,
        final_satisfied: true
      )
      asks = []
      events = []

      result = runtime(root, model, asks:).run("Make Broken.answer equal 42") do |event|
        events << event
      end

      assert result.satisfied
      assert_equal 42, load_value(root)
      structural_revisions = events.select do |event|
        event.type == :plan_reviewed &&
          event.data.fetch("phase") == "action" &&
          event.data.fetch("layer") == "structural" &&
          event.data.fetch("decision") == "revise"
      end
      assert_equal 2, structural_revisions.length
      assert_includes structural_revisions.first.data.fetch("issues"), "action plan must run a configured check"
      assert_includes structural_revisions.last.data.fetch("issues"), "action plan must not mutate after its final configured check"
      assert_equal %w[run_check], ask_tools(asks)
    end
  end

  private

  def scripted_model(plans:, reviews:, final_satisfied:, fixed_failure: false)
    ScriptedModel.new(
      plan: plans,
      review: Array.new(reviews) { accepted_review },
      verify: [
        {
          "answer" => fixed_failure ? "The check still fails." : "Repair processing completed.",
          "satisfied" => final_satisfied,
          "evidence" => ["configured check receipts"]
        }
      ]
    )
  end

  def runtime(root, model, asks:, fixed_failure: false, checks: nil)
    build_runtime(
      root,
      model,
      fixed_failure:,
      checks: checks || answer_checks("answer"),
      ask: lambda do |**request|
        asks << request
        "approve"
      end
    )
  end

  def build_runtime(root, model, ask:, fixed_failure: false, checks: nil)
    checks ||= answer_checks("answer")
    check_code = ->(name) do
      if fixed_failure
        "require './broken'; abort('same failure') unless Broken.answer == 42"
      else
        "require './broken'; abort(\"wrong answer \#{Broken.answer}\") unless Broken.answer == 42"
      end
    end
    Tamoz::Agent.build(
      model:,
      root:,
      allow_changes: true,
      checks:,
      ask:
    )
  end

  def answer_checks(*names, failure: nil)
    condition = failure || "wrong answer \#{Broken.answer}"
    names.to_h do |name|
      [name, [RbConfig.ruby, "-I.", "-e", "require './broken'; abort(\"#{condition}\") unless Broken.answer == 42"]]
    end
  end

  def discovery_plan
    plan(
      step(
        id: "inspect",
        tool: "read_file",
        arguments: {"path" => "broken.rb"}
      )
    )
  end

  def action_plan(from:, to:, check: "answer")
    plan(
      step(
        id: "patch-#{from}-#{to}",
        tool: "apply_patch",
        arguments: {
          "path" => "broken.rb",
          "expected_sha256" => Digest::SHA256.hexdigest(value_source(from)),
          "before" => "def self.answer = #{from}",
          "after" => "def self.answer = #{to}"
        }
      ),
      step(
        id: "check-#{to}",
        tool: "run_check",
        arguments: {"name" => check}
      )
    )
  end

  def action_plan_with_trailing_check(from:, to:, check:, trailing_check:)
    plan(
      step(
        id: "patch-#{from}-#{to}",
        tool: "apply_patch",
        arguments: {
          "path" => "broken.rb",
          "expected_sha256" => Digest::SHA256.hexdigest(value_source(from)),
          "before" => "def self.answer = #{from}",
          "after" => "def self.answer = #{to}"
        }
      ),
      step(id: "check-#{to}", tool: "run_check", arguments: {"name" => check}),
      step(id: "check-#{trailing_check}", tool: "run_check", arguments: {"name" => trailing_check})
    )
  end

  def plan(*steps)
    {
      "goal" => "Make Broken.answer equal 42.",
      "done_when" => ["The configured answer check exits zero."],
      "steps" => steps
    }
  end

  def step(id:, tool:, arguments:)
    {
      "id" => id,
      "purpose" => "Perform #{id}.",
      "tool" => tool,
      "arguments" => arguments,
      "verification" => "Use the observed tool receipt."
    }
  end

  def accepted_review
    {
      "decision" => "accept",
      "issues" => [],
      "rationale" => "The plan is bounded, evidence-backed, and verifiable."
    }
  end

  def write_value(root, value)
    File.write(File.join(root, "broken.rb"), value_source(value))
  end

  def value_source(value)
    <<~RUBY
      module Broken
        def self.answer = #{value}
      end
    RUBY
  end

  def load_value(root)
    source = File.read(File.join(root, "broken.rb"))
    Integer(source.match(/answer = (\d+)/)[1])
  end

  def ask_tools(asks)
    asks.map { |entry| entry.fetch(:tool) }
  end
end
