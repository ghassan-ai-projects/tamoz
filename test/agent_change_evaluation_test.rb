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
    with_broken_project do |root, original|
      model = repair_model(original)
      asks = []
      events = []
      runtime = repair_runtime(root:, model:, asks:)
      result = runtime.run('Fix Broken.answer so the acceptance check passes') { |event| events << event }

      assert_repair_outcome(result, root:, asks:, events:)
      assert_model_input(model, original:)
      %w[apply_patch run_check].each { |tool| assert_action_gate_order(events, tool:) }
    end
  end

  def test_denied_check_is_a_structured_result_and_leaves_no_false_success
    Dir.mktmpdir('tamoz-change-eval') do |root|
      original = "VALUE = 1\n"
      path = File.join(root, 'value.rb')
      File.write(path, original)
      model = denied_check_model(original)
      runtime = Tamoz::Agent.build(
        model:, root:, allow_changes: true,
        checks: { 'value' => [RbConfig.ruby, '-e', 'exit 0'] }, ask: ->(**) { 'deny' }
      )
      result = runtime.run('Change VALUE') { |_event| }

      refute result.satisfied
      denial = result.observations.find { |entry| entry.dig('failure', 'error_class') == 'ToolPolicyError' }
      assert denial, 'expected a structured ToolPolicyError denial observation'
      assert_includes denial.fetch('failure').fetch('reason'), 'denied by operator'
      assert_includes File.read(path), 'VALUE ='
    end
  end

  private

  def with_broken_project
    Dir.mktmpdir('tamoz-change-eval') do |root|
      original = "module Broken\n  def self.answer = 41\nend\n"
      File.write(File.join(root, 'broken.rb'), original)
      yield root, original
    end
  end

  def repair_model(original)
    accepted = { 'decision' => 'accept', 'issues' => [],
                 'rationale' => 'The plan is bounded and directly verified.' }
    ScriptedModel.new(
      plan: [discovery_plan, action_plan(original)], review: [accepted, accepted],
      verify: [{ 'answer' => 'Changed Broken.answer to 42 and the configured check passed.',
                 'satisfied' => true, 'evidence' => ['apply_patch receipt', 'answer check exit_0'] }]
    )
  end

  def discovery_plan
    plan(step(id: 'inspect', tool: 'read_file', arguments: { 'path' => 'broken.rb' },
              purpose: 'Inspect the failing implementation.'))
  end

  def action_plan(original)
    plan(
      step(id: 'patch', tool: 'apply_patch', purpose: 'Correct the implementation.',
           arguments: { 'path' => 'broken.rb', 'expected_sha256' => Digest::SHA256.hexdigest(original),
                        'before' => 'def self.answer = 41', 'after' => 'def self.answer = 42' }),
      step(id: 'test', tool: 'run_check', arguments: { 'name' => 'answer' },
           purpose: 'Run the configured acceptance check.')
    )
  end

  def repair_runtime(root:, model:, asks:)
    Tamoz::Agent.build(
      model:, root:, allow_changes: true,
      checks: { 'answer' => [RbConfig.ruby, '-I.', '-e',
                             "require './broken'; abort('wrong answer') unless Broken.answer == 42"] },
      ask: lambda do |**request|
        asks << request
        'approve'
      end
    )
  end

  def assert_repair_outcome(result, root:, asks:, events:)
    assert result.satisfied
    assert_includes File.read(File.join(root, 'broken.rb')), 'answer = 42'
    assert_equal %w[run_check], asks.map { |entry| entry.fetch(:tool) }
    granted = events.select { |event| event.type == :approval_granted }.map { |event| event.data.fetch('tool') }
    assert_equal %w[read_file apply_patch run_check], granted.uniq
    check = result.observations.find { |entry| entry.fetch('tool') == 'run_check' }
    assert_includes check.fetch('output'), 'exit_0'
  end

  def assert_model_input(model, original:)
    assert_equal %i[plan review plan review verify], model.calls.map { |entry| entry.fetch(:stage) }
    assert_includes model.calls.fetch(2).fetch(:prompt), Digest::SHA256.hexdigest(original)
  end

  def assert_action_gate_order(events, tool:)
    accepted = events.index { |event| event.type == :plan_accepted && event.data.fetch('phase') == 'action' }
    requested = action_event_index(events, :approval_requested, tool:)
    granted = action_event_index(events, :approval_granted, tool:)
    started = action_event_index(events, :tool_started, tool:)
    assert requested, "no gate decision for #{tool}"
    assert_operator accepted, :<, requested
    assert_operator requested, :<, granted
    assert_operator granted, :<, started
  end

  def action_event_index(events, type, tool:)
    events.index do |event|
      event.type == type && event.data.fetch('tool') == tool && event.data.fetch('phase') == 'action'
    end
  end

  def denied_check_model(original)
    ScriptedModel.new(
      plan: [plan(step(id: 'inspect', tool: 'read_file', arguments: { 'path' => 'value.rb' })),
             plan(value_patch_step(before: '1', after: '2', digest: Digest::SHA256.hexdigest(original)), value_check_step),
             plan(value_patch_step(before: '2', after: '3', digest: Digest::SHA256.hexdigest("VALUE = 2\n")), value_check_step)],
      review: Array.new(3) { accepted_review },
      verify: [{ 'answer' => 'The operator denied the asked check.', 'satisfied' => false, 'evidence' => [] }]
    )
  end

  def value_patch_step(before:, after:, digest:)
    step(id: 'patch', tool: 'apply_patch',
         arguments: { 'path' => 'value.rb', 'expected_sha256' => digest, 'before' => before, 'after' => after })
  end

  def value_check_step
    step(id: 'check', tool: 'run_check', arguments: { 'name' => 'value' })
  end

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
