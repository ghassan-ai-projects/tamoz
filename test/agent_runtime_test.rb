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
      refute_includes model.calls.fetch(0).fetch(:prompt), "planning_context"
      refute_includes model.calls.fetch(1).fetch(:prompt), "planning_context"
      refute_includes model.calls.fetch(2).fetch(:prompt), "verification_context"
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

  def test_compound_apply_patch_signature_is_stable_across_before_order
    Dir.mktmpdir("tamoz-agent") do |root|
      runtime = build_runtime(root)
      plan_a = Tamoz::Agent::Plan.parse(plan_for("apply_patch",
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => [
          {"before" => "a", "after" => "1"},
          {"before" => "b", "after" => "2"}
        ]
      ))
      plan_b = Tamoz::Agent::Plan.parse(plan_for("apply_patch",
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => [
          {"before" => "b", "after" => "2"},
          {"before" => "a", "after" => "1"}
        ]
      ))

      assert_equal runtime.send(:action_signature, plan_a), runtime.send(:action_signature, plan_b)
    end
  end

  def test_compound_apply_patch_signature_changes_when_within_before_order_changes
    Dir.mktmpdir("tamoz-agent") do |root|
      original = "X = 1\nX = 2\n"
      digest = Digest::SHA256.hexdigest(original)
      args_first = {
        "path" => "x.rb",
        "expected_sha256" => digest,
        "replacements" => [
          {"before" => "X = 1", "after" => "A"},
          {"before" => "X = 2", "after" => "B"}
        ]
      }
      args_second = {
        "path" => "x.rb",
        "expected_sha256" => digest,
        "replacements" => [
          {"before" => "X = 1", "after" => "B"},
          {"before" => "X = 2", "after" => "A"}
        ]
      }

      runtime = build_runtime(root)
      sig_first = runtime.send(:action_signature, Tamoz::Agent::Plan.parse(plan_for("apply_patch", args_first)))
      sig_second = runtime.send(:action_signature, Tamoz::Agent::Plan.parse(plan_for("apply_patch", args_second)))
      refute_equal sig_first, sig_second

      first_result = nil
      Dir.mktmpdir("tamoz-agent-first") do |first_root|
        File.write(File.join(first_root, "x.rb"), original)
        Tamoz::Agent::Toolbox.new(root: first_root, allow_changes: true).execute("apply_patch", args_first)
        first_result = File.read(File.join(first_root, "x.rb"))
      end
      second_result = nil
      Dir.mktmpdir("tamoz-agent-second") do |second_root|
        File.write(File.join(second_root, "x.rb"), original)
        Tamoz::Agent::Toolbox.new(root: second_root, allow_changes: true).execute("apply_patch", args_second)
        second_result = File.read(File.join(second_root, "x.rb"))
      end
      refute_equal first_result, second_result
    end
  end

  def test_approval_denial_stops_compound_patch_before_write
    Dir.mktmpdir("tamoz-agent") do |root|
      path = File.join(root, "values.rb")
      original = "A = 1\nB = 2\n"
      File.write(path, original)
      digest = Digest::SHA256.hexdigest(original)
      discovery_plan = plan_for("read_file", "path" => "values.rb")
      action_plan = plan_for("apply_patch", {
        "path" => "values.rb",
        "expected_sha256" => digest,
        "replacements" => [
          {"before" => "A = 1", "after" => "A = 2"},
          {"before" => "B = 2", "after" => "B = 3"}
        ]
      })
      model = ScriptedModel.new(
        plan: [discovery_plan, action_plan],
        review: [accepted_review, accepted_review],
        verify: []
      )
      runtime = Tamoz::Agent.build(model:, root:, allow_changes: true, approval: ->(**) { false })
      events = []

      assert_raises(Tamoz::Agent::ApprovalDeniedError) do
        runtime.run("Update values") { |event| events << event }
      end
      assert events.any? { |event| event.type == :approval_requested }
      refute events.any? { |event| event.type == :tool_started && event.data.fetch("tool") == "apply_patch" }
      assert_equal original, File.read(path)
    end
  end

  def test_two_compound_patches_in_one_plan_are_separate_approvals
    Dir.mktmpdir("tamoz-agent") do |root|
      File.write(File.join(root, "a.rb"), "A = 1\n")
      File.write(File.join(root, "b.rb"), "B = 1\n")
      discovery_plan = plan_for("read_file", "path" => "a.rb")
      action_plan = {
        "goal" => "Update both files",
        "done_when" => ["Both files are updated."],
        "steps" => [
          {
            "id" => "patch_a",
            "purpose" => "Update a.rb.",
            "tool" => "apply_patch",
            "arguments" => {
              "path" => "a.rb",
              "expected_sha256" => Digest::SHA256.hexdigest("A = 1\n"),
              "replacements" => [{"before" => "A = 1", "after" => "A = 2"}]
            },
            "verification" => "a.rb reads A = 2."
          },
          {
            "id" => "patch_b",
            "purpose" => "Update b.rb.",
            "tool" => "apply_patch",
            "arguments" => {
              "path" => "b.rb",
              "expected_sha256" => Digest::SHA256.hexdigest("B = 1\n"),
              "replacements" => [{"before" => "B = 1", "after" => "B = 2"}]
            },
            "verification" => "b.rb reads B = 2."
          }
        ]
      }
      approvals = []
      model = ScriptedModel.new(
        plan: [discovery_plan, action_plan],
        review: [accepted_review, accepted_review],
        verify: [{"answer" => "done", "satisfied" => true, "evidence" => ["a.rb", "b.rb"]}]
      )
      runtime = Tamoz::Agent.build(model:, root:, allow_changes: true, approval: ->(**) { approvals << true; true })

      runtime.run("Update both files")

      assert_equal 2, approvals.length
      assert_equal "A = 2\n", File.read(File.join(root, "a.rb"))
      assert_equal "B = 2\n", File.read(File.join(root, "b.rb"))
    end
  end

  private

  def build_runtime(root)
    model = Class.new do
      def generate(**); end
    end.new
    Tamoz::Agent::Runtime.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
    )
  end

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
