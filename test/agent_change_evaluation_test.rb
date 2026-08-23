# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class AgentChangeEvaluationTest < Minitest::Test
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

  def test_end_to_end_evaluation_repairs_a_broken_ruby_project
    Dir.mktmpdir("tamoz-change-eval") do |root|
      original = <<~RUBY
        module Broken
          def self.answer = 41
        end
      RUBY
      File.write(File.join(root, "broken.rb"), original)
      discovery = plan(
        step(
          id: "inspect",
          tool: "read_file",
          arguments: {"path" => "broken.rb"},
          purpose: "Inspect the failing implementation."
        )
      )
      action = plan(
        step(
          id: "patch",
          tool: "apply_patch",
          arguments: {
            "path" => "broken.rb",
            "expected_sha256" => Digest::SHA256.hexdigest(original),
            "before" => "def self.answer = 41",
            "after" => "def self.answer = 42"
          },
          purpose: "Correct the implementation."
        ),
        step(
          id: "test",
          tool: "run_check",
          arguments: {"name" => "answer"},
          purpose: "Run the configured acceptance check."
        )
      )
      accepted = {
        "decision" => "accept",
        "issues" => [],
        "rationale" => "The plan is bounded and directly verified."
      }
      model = ScriptedModel.new(
        plan: [discovery, action],
        review: [accepted, accepted],
        verify: [
          {
            "answer" => "Changed Broken.answer to 42 and the configured check passed.",
            "satisfied" => true,
            "evidence" => ["apply_patch receipt", "answer check exit_0"]
          }
        ]
      )
      asks = []
      events = []
      runtime = Tamoz::Agent.build(
        model:,
        root:,
        allow_changes: true,
        checks: {
          "answer" => [
            RbConfig.ruby,
            "-I.",
            "-e",
            "require './broken'; abort('wrong answer') unless Broken.answer == 42"
          ]
        },
        ask: lambda do |**request|
          asks << request
          "approve"
        end
      )

      result = runtime.run("Fix Broken.answer so the acceptance check passes") do |event|
        events << event
      end

      assert result.satisfied
      assert_includes File.read(File.join(root, "broken.rb")), "answer = 42"
      # Policy data decides what asks: under the implement profile apply_patch is
      # workspace_write (auto-allow), run_check is local_execute (ask).
      assert_equal %w[run_check], asks.map { |entry| entry.fetch(:tool) }
      granted = events.select { |event| event.type == :approval_granted }.map { |event| event.data.fetch("tool") }
      # The engine decides EVERY step; each executed tool carries a permitting
      # decision before it runs.
      assert_equal %w[read_file apply_patch run_check], granted.uniq
      check = result.observations.find { |entry| entry.fetch("tool") == "run_check" }
      assert_includes check.fetch("output"), "exit_0"
      assert_equal %i[plan review plan review verify], model.calls.map { |entry| entry.fetch(:stage) }
      assert_includes model.calls.fetch(2).fetch(:prompt), Digest::SHA256.hexdigest(original)

      action_accept = events.index do |event|
        event.type == :plan_accepted && event.data.fetch("phase") == "action"
      end
      # Every gated step runs only after its own engine decision: requested,
      # then granted, then the tool itself.
      %w[apply_patch run_check].each do |tool|
        requested = events.index { |event| event.type == :approval_requested && event.data.fetch("tool") == tool && event.data.fetch("phase") == "action" }
        granted = events.index { |event| event.type == :approval_granted && event.data.fetch("tool") == tool && event.data.fetch("phase") == "action" }
        started = events.index { |event| event.type == :tool_started && event.data.fetch("tool") == tool && event.data.fetch("phase") == "action" }
        assert requested, "no gate decision for #{tool}"
        assert_operator action_accept, :<, requested
        assert_operator requested, :<, granted
        assert_operator granted, :<, started
      end
    end
  end

  def test_denied_check_is_a_structured_result_and_leaves_no_false_success
    Dir.mktmpdir("tamoz-change-eval") do |root|
      original = "VALUE = 1\n"
      path = File.join(root, "value.rb")
      File.write(path, original)
      model = ScriptedModel.new(
        plan: [
          plan(step(id: "inspect", tool: "read_file", arguments: {"path" => "value.rb"})),
          plan(
            step(
              id: "patch",
              tool: "apply_patch",
              arguments: {
                "path" => "value.rb",
                "expected_sha256" => Digest::SHA256.hexdigest(original),
                "before" => "1",
                "after" => "2"
              }
            ),
            step(id: "check", tool: "run_check", arguments: {"name" => "value"})
          ),
          plan(
            step(
              id: "patch",
              tool: "apply_patch",
              arguments: {
                "path" => "value.rb",
                "expected_sha256" => Digest::SHA256.hexdigest("VALUE = 2\n"),
                "before" => "2",
                "after" => "3"
              }
            ),
            step(id: "check", tool: "run_check", arguments: {"name" => "value"})
          )
        ],
        review: [accepted_review, accepted_review, accepted_review],
        verify: [
          {
            "answer" => "The operator denied the asked check.",
            "satisfied" => false,
            "evidence" => []
          }
        ]
      )
      runtime = Tamoz::Agent.build(
        model:,
        root:,
        allow_changes: true,
        checks: {"value" => [RbConfig.ruby, "-e", "exit 0"]},
        ask: ->(**) { "deny" }
      )

      result = runtime.run("Change VALUE") { |_event| }

      refute result.satisfied
      denial = result.observations.find do |entry|
        entry.dig("failure", "error_class") == "ToolPolicyError"
      end
      assert denial, "expected a structured ToolPolicyError denial observation"
      assert_includes denial.fetch("failure").fetch("reason"), "denied by operator"
      assert_includes File.read(path), "VALUE ="
    end
  end

  private

  def plan(*steps)
    {
      "goal" => "Complete the requested repair.",
      "done_when" => ["The configured check passes."],
      "steps" => steps
    }
  end

  def step(id:, tool:, arguments:, purpose: "Perform the bounded step.")
    {
      "id" => id,
      "purpose" => purpose,
      "tool" => tool,
      "arguments" => arguments,
      "verification" => "Compare the observed result with the task."
    }
  end

  def accepted_review
    {
      "decision" => "accept",
      "issues" => [],
      "rationale" => "The plan is bounded and verifiable."
    }
  end
end
