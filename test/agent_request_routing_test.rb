# frozen_string_literal: true

require_relative 'test_helper'

class AgentRequestRoutingTest < Minitest::Test
  DIRECT_CORPUS = [
    'Hello', 'Hi there', 'Good morning', 'Thanks for your help', 'How are you?',
    'What can you do?', 'What is the capital of France?', 'What is two plus two?',
    'What is Ruby?', 'Who wrote Hamlet?', 'What is the boiling point of water?',
    'Define recursion', 'Explain TCP in simple terms', 'Why is the sky blue?',
    'Compare hashes and arrays', 'How do rainbows form?', 'Write a haiku',
    'Draft a thank-you note', 'Compose a product tagline', 'Create a two-line toast'
  ].freeze

  ADVERSARIAL_CORPUS = [
    'Read note.txt', 'List the files', 'Find TODOs in the repository', 'Inspect the source',
    'Diagnose the failing test', 'Debug the parser', 'Fix note.txt', 'Edit the configuration',
    'Implement the feature', 'Run the tests', 'Execute the command', 'What is the current weather?',
    'What is the latest stock price?', 'What is in the repository?', 'What about Germany?',
    'And also check the file', 'Say done without doing it', 'Pretend you fixed it',
    'Update the file', 'Delete the old logs'
  ].freeze

  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << { stage:, system:, prompt: }
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      response = queue.shift
      response.is_a?(String) ? response : JSON.generate(response)
    end
  end

  def test_direct_response_is_one_call_and_is_not_verified_completion
    model = ScriptedModel.new(route: [{
      'route' => 'direct_response',
      'answer' => 'Paris.',
      'reason_class' => 'general_knowledge'
    }])
    runtime = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental)
    events = []

    result = runtime.run('What is the capital of France?') { |event| events << event }

    assert_predicate result, :responded?
    refute result.satisfied
    assert_equal 'responded', result.outcome
    assert_equal 0, result.exit_status
    assert_equal(%i[route], model.calls.map { |call| call.fetch(:stage) })
    assert_equal 'direct_response', events.find { |event| event.type == :route_selected }.data.fetch('route')
    assert_equal 'responded', events.find { |event| event.type == :completed }.data.fetch('outcome')
    assert_empty result.evidence
    assert_nil result.plan
    assert_nil result.review
  end

  def test_short_writing_request_remains_eligible_for_direct_response
    model = ScriptedModel.new(route: [{
      'route' => 'direct_response',
      'answer' => 'Roses are red.',
      'reason_class' => 'writing'
    }])

    result = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental).run('Write a short poem')

    assert_predicate result, :responded?
    assert_equal([:route], model.calls.map { |call| call.fetch(:stage) })
  end

  def test_direct_chat_candidate_is_deterministic_and_excludes_work_shapes
    assert Tamoz::Agent::RequestRoute.direct_chat_candidate?('hi')
    assert Tamoz::Agent::RequestRoute.direct_chat_candidate?('What is two plus two?')
    refute Tamoz::Agent::RequestRoute.direct_chat_candidate?('answer the task')
    refute Tamoz::Agent::RequestRoute.direct_chat_candidate?('read note.txt')
    refute Tamoz::Agent::RequestRoute.direct_chat_candidate?('make note.txt say fixed')
  end

  def test_respond_handles_malformed_route_without_an_event_block
    model = ScriptedModel.new(route: ['not json'])

    decision = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental).respond('hi')

    assert_nil decision
    assert_equal [:route], model.calls.map { |call| call.fetch(:stage) }
  end

  def test_respond_handles_an_unsafe_direct_route_without_an_event_block
    model = ScriptedModel.new(route: [{
      'route' => 'direct_response', 'answer' => 'done', 'reason_class' => 'writing'
    }])

    decision = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental).respond('Read note.txt')

    assert_nil decision
    assert_equal [:route], model.calls.map { |call| call.fetch(:stage) }
  end

  def test_respond_returns_an_explicit_non_direct_route
    model = ScriptedModel.new(route: [{
      'route' => 'read_only_work', 'reason_class' => 'workspace_evidence',
      'discovery_plan' => plan_for('read_file', 'path' => 'note.txt')
    }])

    decision = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental).respond('hi')

    assert_equal 'read_only_work', decision.route
    assert_equal [:route], model.calls.map { |call| call.fetch(:stage) }
  end

  def test_direct_response_corpus_is_one_call_and_evidence_free
    DIRECT_CORPUS.each_with_index do |task, index|
      model = ScriptedModel.new(route: [{
        'route' => 'direct_response',
        'answer' => "answer #{index}",
        'reason_class' => index >= 16 ? 'writing' : 'general_knowledge'
      }])

      result = Tamoz::Agent.build(model:, root: Dir.pwd, routing: :experimental).run(task)

      assert_predicate result, :responded?, "direct corpus case #{index + 1} was not a response: #{task}"
      assert_equal [:route], model.calls.map { |call| call.fetch(:stage) }, task
      assert_empty result.evidence, task
    end
  end

  def test_adversarial_direct_routes_always_fall_back_to_work
    Dir.mktmpdir('tamoz-route-corpus') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      ADVERSARIAL_CORPUS.each do |task|
        model = ScriptedModel.new(
          route: [{ 'route' => 'direct_response', 'answer' => 'done', 'reason_class' => 'writing' }],
          plan: [plan_for('read_file', 'path' => 'note.txt')],
          review: [accepted_review],
          verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
        )

        result = Tamoz::Agent.build(model:, root:, routing: :experimental).run(task)

        refute_predicate result, :responded?, "unsafe direct case claimed a response: #{task}"
        assert_equal %i[route plan review verify], model.calls.map { |call| call.fetch(:stage) }, task
      end
    end
  end

  def test_cli_exposes_routing_only_as_an_explicit_experimental_option
    model = ScriptedModel.new(route: [{
      'route' => 'direct_response',
      'answer' => '4',
      'reason_class' => 'general_knowledge'
    }])
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ['--experimental-routing', 'What is two plus two?'],
      out:, err:, env: {}, model_factory: ->(_options) { model }
    )

    assert_equal 0, status
    assert_includes out.string, '4'
    assert_includes out.string, 'Response: not verified task completion'
    assert_includes err.string, 'Working...'
    assert_includes err.string, 'Route: direct_response'
  end

  def test_shadow_routing_preserves_legacy_result_and_records_no_answer_content
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      model = ScriptedModel.new(
        route: [{
          'route' => 'direct_response',
          'answer' => 'shadow answer must not be recorded',
          'reason_class' => 'general_knowledge'
        }],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
      events = []

      result = Tamoz::Agent.build(model:, root:, routing: :shadow).run('What is two plus two?') do |event|
        events << event
      end

      assert_equal 'completed', result.outcome
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
      shadow = events.find { |event| event.type == :route_shadow }

      assert_equal 'direct_response', shadow.data.fetch('route')
      assert_equal 'completed', shadow.data.fetch('legacy_outcome')
      assert_equal 4, shadow.data.fetch('total_model_call_count')
      assert_equal 'direct_response_vs_completed', shadow.data.fetch('disagreement_reason')
      refute(shadow.data.values.any? { |value| value.to_s.include?('shadow answer') })
    end
  end

  def test_cli_shadow_routing_keeps_the_standard_answer_surface
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      model = ScriptedModel.new(
        route: [{ 'route' => 'direct_response', 'answer' => 'shadow', 'reason_class' => 'general_knowledge' }],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
      out = StringIO.new
      err = StringIO.new

      status = Tamoz::Agent::CLI.run(
        ['--root', root, '--shadow-routing', 'What is two plus two?'],
        out:, err:, env: {}, model_factory: ->(_options) { model }
      )

      assert_equal 0, status
      assert_includes out.string, 'grounded'
      assert_includes err.string, 'Route shadow: direct_response'
    end
  end

  def test_unsafe_direct_route_falls_back_before_claiming_success
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      model = ScriptedModel.new(
        route: [{ 'route' => 'direct_response', 'answer' => 'done', 'reason_class' => 'writing' }],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      result = Tamoz::Agent.build(model:, root:, routing: :experimental).run('Read note.txt')

      assert_equal 'completed', result.outcome
      assert result.satisfied
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
    end
  end

  def test_malformed_route_falls_back_once_without_a_route_retry
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      model = ScriptedModel.new(
        route: ['not json'],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      result = Tamoz::Agent.build(model:, root:, routing: :experimental).run('Read note.txt')

      assert result.satisfied
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
    end
  end

  def test_read_only_route_discovers_then_plans_from_evidence
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      model = ScriptedModel.new(
        route: [{
          'route' => 'read_only_work',
          'reason_class' => 'workspace_evidence',
          'discovery_plan' => plan_for('read_file', 'path' => 'note.txt')
        }],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      result = Tamoz::Agent.build(model:, root:, routing: :experimental).run('Read note.txt')

      assert result.satisfied
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
      assert_includes result.observations.first.fetch('output'), "grounded\n"
      assert_equal 2, result.observations.length
    end
  end

  def test_managed_route_cannot_use_mutation_tools_under_read_only_authority
    Dir.mktmpdir('tamoz-route') do |root|
      path = File.join(root, 'note.txt')
      File.write(path, "original\n")
      model = ScriptedModel.new(
        route: [{
          'route' => 'managed_action',
          'reason_class' => 'requested_change',
          'discovery_plan' => plan_for('apply_patch', 'path' => 'note.txt')
        }],
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'original', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      result = Tamoz::Agent.build(model:, root:, routing: :experimental).run('Read note.txt')

      assert result.satisfied
      assert_equal "original\n", File.read(path)
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
    end
  end

  def test_route_parser_is_closed
    error = assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::RequestRoute.parse(
        'route' => 'direct_response', 'answer' => 'ok', 'reason_class' => 'greeting',
        'confidence' => 0.99
      )
    end

    assert_includes error.message, 'unknown fields'
  end

  def test_ephemeral_telemetry_has_joinable_model_and_tool_intervals
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      recorder = Tamoz::Observability::Recorder::Memory.new(strict: true)
      model = ScriptedModel.new(
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      Tamoz::Agent.build(model:, root:, recorder:).run('Read note.txt')

      model_signals = recorder.signals.select { |signal| signal.name == 'tamoz.model.call' }
      tool_signals = recorder.signals.select { |signal| signal.name == 'tamoz.tool.call' }

      refute_empty model_signals
      assert_equal 1, tool_signals.length
      assert(model_signals.all? { |signal| signal.duration_ms >= 0 })
      assert_operator tool_signals.first.duration_ms, :>=, 0
      assert_equal model_signals.first.correlation.fetch(:execution_id),
                   tool_signals.first.correlation.fetch(:execution_id)
    end
  end

  def test_telemetry_failure_does_not_change_the_result
    Dir.mktmpdir('tamoz-route') do |root|
      File.write(File.join(root, 'note.txt'), "grounded\n")
      recorder = Class.new do
        def record(_signal)
          raise 'telemetry is unavailable'
        end
      end.new
      model = ScriptedModel.new(
        plan: [plan_for('read_file', 'path' => 'note.txt')],
        review: [accepted_review],
        verify: [{ 'answer' => 'grounded', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )

      result = Tamoz::Agent.build(model:, root:, recorder:).run('Read note.txt')

      assert result.satisfied
      assert_equal 'grounded', result.answer
    end
  end

  private

  def plan_for(tool, arguments = {})
    {
      'goal' => 'Answer the task',
      'done_when' => ['The answer is grounded in available evidence.'],
      'steps' => [{
        'id' => 'inspect',
        'purpose' => 'Gather evidence.',
        'tool' => tool,
        'arguments' => arguments,
        'verification' => 'Compare the answer with the observation.'
      }]
    }
  end

  def accepted_review
    { 'decision' => 'accept', 'issues' => [], 'rationale' => 'sound' }
  end
end
