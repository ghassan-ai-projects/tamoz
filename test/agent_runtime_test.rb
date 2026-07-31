# frozen_string_literal: true

require_relative "test_helper"

class AgentRuntimeTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      queue.shift
    end
  end

  def test_runs_a_reviewed_plan_before_reading_and_verifies_the_answer
    Dir.mktmpdir("tamoz-agent") do |root|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", "path" => "note.txt")],
        review: [accepted_review],
        verify: [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      events = []

      result = Tamoz::Agent.build(model:, root:).run("What does note.txt say?") do |event|
        events << event
      end

      assert result.satisfied
      assert_equal "Tamoz is awake.", result.answer
      assert_includes result.observations.first.fetch("output"), "Tamoz is awake."
      assert_includes result.observations.first.fetch("output"), "sha256:"
      assert_operator event_index(events, :plan_accepted), :<, event_index(events, :tool_started)
      assert_equal %i[plan review verify], model.calls.map { |call| call.fetch(:stage) }
      assert_includes model.calls.last.fetch(:prompt), "Tamoz is awake."
      refute_includes model.calls.first.fetch(:prompt), root
    end
  end

  def test_structural_review_rejects_an_unavailable_tool_before_any_action
    Dir.mktmpdir("tamoz-agent") do |root|
      File.write(File.join(root, "note.txt"), "safe\n")
      model = ScriptedModel.new(
        plan: [
          plan_for("delete_everything", "path" => "."),
          plan_for("read_file", "path" => "note.txt")
        ],
        review: [accepted_review],
        verify: [{"answer" => "safe", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      events = []

      Tamoz::Agent.build(model:, root:).run("Read the note") { |event| events << event }

      structural = events.select do |event|
        event.type == :plan_reviewed && event.data.fetch("layer") == "structural"
      end
      assert_equal %w[revise accept], structural.map { |event| event.data.fetch("decision") }
      assert_equal 1, events.count { |event| event.type == :tool_started }
      assert_equal %i[plan plan review verify], model.calls.map { |call| call.fetch(:stage) }
    end
  end

  def test_structural_review_rejects_invalid_tool_arguments_before_any_action
    Dir.mktmpdir("tamoz-agent") do |root|
      File.write(File.join(root, "note.txt"), "safe\n")
      model = ScriptedModel.new(
        plan: [
          plan_for("read_file", "path" => "/etc/passwd"),
          plan_for("read_file", "path" => "note.txt")
        ],
        review: [accepted_review],
        verify: [{"answer" => "safe", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      events = []

      Tamoz::Agent.build(model:, root:).run("Read the note") { |event| events << event }

      first_review = events.find do |event|
        event.type == :plan_reviewed && event.data.fetch("layer") == "structural"
      end
      assert_equal "revise", first_review.data.fetch("decision")
      assert_includes first_review.data.fetch("issues").join(" "), "relative"
      assert_equal 1, events.count { |event| event.type == :tool_started }
    end
  end

  def test_protocol_rejects_non_string_tool_without_executing_it
    Dir.mktmpdir("tamoz-agent") do |root|
      invalid = plan_for(nil)
      invalid.fetch("steps").first["tool"] = false
      model = ScriptedModel.new(plan: [invalid], review: [], verify: [])
      events = []

      assert_raises(Tamoz::Agent::PlanRejectedError) do
        Tamoz::Agent.build(model:, root:, max_plan_attempts: 1).run("Inspect") do |event|
          events << event
        end
      end
      refute events.any? { |event| event.type == :tool_started }
    end
  end

  def test_semantic_reviewer_can_force_replanning_before_action
    Dir.mktmpdir("tamoz-agent") do |root|
      File.write(File.join(root, "note.txt"), "reviewed\n")
      model = ScriptedModel.new(
        plan: [plan_for(nil), plan_for("read_file", "path" => "note.txt")],
        review: [
          {"decision" => "revise", "issues" => ["Inspect the named file."], "rationale" => "Evidence needed."},
          accepted_review
        ],
        verify: [{"answer" => "reviewed", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      events = []

      Tamoz::Agent.build(model:, root:).run("Read note.txt") { |event| events << event }

      assert_equal 2, events.count { |event| event.type == :plan_drafted }
      assert_operator event_index(events, :plan_accepted), :<, event_index(events, :tool_started)
    end
  end

  def test_never_executes_when_no_plan_passes_review
    Dir.mktmpdir("tamoz-agent") do |root|
      model = ScriptedModel.new(
        plan: [plan_for("shell", "command" => "whoami")],
        review: [],
        verify: []
      )
      runtime = Tamoz::Agent.build(model:, root:, max_plan_attempts: 1)
      events = []

      assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime.run("Run a command") { |event| events << event }
      end
      refute events.any? { |event| event.type == :tool_started }
    end
  end

  def test_toolbox_rejects_symlink_escape
    Dir.mktmpdir("tamoz-agent-root") do |root|
      Dir.mktmpdir("tamoz-agent-outside") do |outside|
        File.write(File.join(outside, "secret.txt"), "secret")
        File.symlink(outside, File.join(root, "escape"))
        toolbox = Tamoz::Agent::Toolbox.new(root:)

        error = assert_raises(Tamoz::Agent::ToolError) do
          toolbox.execute("read_file", "path" => "escape/secret.txt")
        end
        assert_match(/escapes/, error.message)
      end
    end
  end

  private

  def plan_for(tool, arguments = {})
    {
      "goal" => "Answer the task",
      "done_when" => ["The answer is grounded in available evidence."],
      "steps" => [
        {
          "id" => "inspect",
          "purpose" => "Gather the evidence needed for the answer.",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "Compare the answer with the observed content."
        }
      ]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "The plan is proportional and verifiable."}
  end

  def event_index(events, type)
    events.index { |event| event.type == type } || flunk("missing #{type} event")
  end
end
