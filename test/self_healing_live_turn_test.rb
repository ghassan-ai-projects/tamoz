# frozen_string_literal: true

require_relative "test_helper"

# Proves self-healing is wired LIVE into the agent turn: a failed action turn
# emits a `:healing_assessment` event carrying the healing vertical's typed
# verdict. The assessment is read-only — it never changes the workspace.
class SelfHealingLiveTurnTest < Minitest::Test
  class ScriptedModel
    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
    end

    def generate(stage:, system:, prompt:)
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      queue.shift
    end
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "proportional and verifiable"}
  end

  def action_plan
    {
      "goal" => "Run the configured check",
      "done_when" => ["The check passes."],
      "steps" => [
        {"id" => "check", "purpose" => "Run the check.", "tool" => "run_check",
         "arguments" => {"name" => "values"}, "verification" => "Use the receipt."}
      ]
    }
  end

  def test_failed_action_turn_emits_a_healing_assessment
    Dir.mktmpdir("tamoz-heal-live") do |root|
      File.write(File.join(root, "a.rb"), "A = 1\n")
      discovery = {"goal" => "Look", "done_when" => ["seen"],
                   "steps" => [{"id" => "r", "purpose" => "read", "tool" => "read_file",
                                "arguments" => {"path" => "a.rb"}, "verification" => "read"}]}
      model = ScriptedModel.new(
        plan: [discovery] + Array.new(4) { action_plan },
        review: Array.new(6) { accepted_review },
        verify: [{"answer" => "the check failed", "satisfied" => false, "evidence" => []}]
      )
      runtime = Tamoz::Agent.build(
        model:, root:, allow_changes: true,
        checks: {"values" => [RbConfig.ruby, "-e", "exit 1"]},
        ask: ->(**) { "approve" }
      )

      events = []
      result = runtime.run("Update values") { |event| events << event }

      refute result.satisfied
      assessment = events.find { |event| event.type == :healing_assessment }
      refute_nil assessment, "a failed action turn must emit a healing assessment"
      assert_equal "verification_failed", assessment.data.fetch("category")
      assert_equal "escalated", assessment.data.fetch("route")
      refute assessment.data.fetch("remediable")
    end
  end
end
