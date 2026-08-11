# frozen_string_literal: true

require_relative 'test_helper'

class AgentDurableRoutingTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << { stage:, system:, prompt: }
      queue = @responses.fetch(stage) { raise "no scripted #{stage} response" }
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def test_direct_response_is_durable_and_truthfully_unverified
    with_workspace do |root, adapter|
      model = ScriptedModel.new(
        route: [{
          'route' => 'direct_response',
          'answer' => 'Paris.',
          'reason_class' => 'general_knowledge'
        }]
      )
      session = build_session(model:, root:, adapter:, routing: :experimental)

      outcome = session.start(
        'What is the capital of France?',
        thread: 'durable.route.direct',
        request_id: 'request.1'
      )

      assert_equal :completed, outcome.status
      assert_equal 'Paris.', outcome.result.answer
      refute outcome.result.satisfied
      assert_nil outcome.result.plan
      assert_equal([:route], model.calls.map { |call| call.fetch(:stage) })
      view = session.view(thread: 'durable.route.direct')

      assert_equal '2', view.state.fetch(:session).fetch('graph_version')
      assert_equal 'direct_response', view.state.fetch(:route).fetch('route')
      assert_equal 'direct_response', view.terminal.fetch('reason')
      assert_empty view.effect_receipts
      assert adapter.integrity_check.fetch('ok')
    end
  end

  def test_read_only_work_uses_durable_discovery_before_read_only_plan
    with_workspace do |root, adapter|
      File.write(File.join(root, 'note.txt'), "Tamoz is awake.\n")
      model = ScriptedModel.new(
        route: [{
          'route' => 'read_only_work',
          'reason_class' => 'workspace_evidence',
          'discovery_plan' => plan_for('list_directory', { 'path' => '.' }, id: 'discover')
        }],
        plan: [plan_for('read_file', { 'path' => 'note.txt' })],
        review: [accepted_review],
        verify: [{ 'answer' => 'Tamoz is awake.', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
      session = build_session(model:, root:, adapter:, routing: :experimental)

      outcome = session.start(
        'What does note.txt say?',
        thread: 'durable.route.discovery',
        request_id: 'request.1'
      )

      assert_equal :completed, outcome.status
      assert outcome.result.satisfied
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
      view = session.view(thread: 'durable.route.discovery')

      assert_equal 'read_only_work', view.state.fetch(:route).fetch('route')
      assert_equal 'read_only', view.accepted_plan.fetch('phase')
      assert_equal 2, view.state.fetch(:plan_versions).length
      assert_equal 3, view.state.fetch(:plan_reviews).length
      assert_equal 2, view.effect_receipts.length
      assert(view.effect_receipts.all? { |receipt| receipt.fetch('safety') == 'read_only' })
      assert adapter.integrity_check.fetch('ok')
    end
  end

  def test_malformed_route_falls_back_without_creating_a_fake_plan
    with_workspace do |root, adapter|
      File.write(File.join(root, 'note.txt'), "fallback\n")
      model = ScriptedModel.new(
        route: ['not json'],
        plan: [plan_for('read_file', { 'path' => 'note.txt' })],
        review: [accepted_review],
        verify: [{ 'answer' => 'fallback', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
      session = build_session(model:, root:, adapter:, routing: :experimental)

      outcome = session.start(
        'Read note.txt',
        thread: 'durable.route.fallback',
        request_id: 'request.1'
      )

      assert_equal :completed, outcome.status
      assert outcome.result.satisfied
      assert_equal(%i[route plan review verify], model.calls.map { |call| call.fetch(:stage) })
      view = session.view(thread: 'durable.route.fallback')

      assert_equal 'legacy_fallback', view.state.fetch(:route).fetch('route')
      assert_equal 'route_protocol_error', view.state.fetch(:route).fetch('fallback')
      assert_equal 1, view.state.fetch(:plan_versions).length
      assert_equal 2, view.state.fetch(:plan_reviews).length
    end
  end

  def test_experimental_session_keeps_selecting_a_legacy_thread_by_checkpoint
    with_workspace do |root, adapter|
      File.write(File.join(root, 'note.txt'), "legacy\n")
      legacy_model = ScriptedModel.new(
        plan: [plan_for('read_file', { 'path' => 'note.txt' })],
        review: [accepted_review],
        verify: [{ 'answer' => 'legacy', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
      legacy = build_session(model: legacy_model, root:, adapter:)
      legacy.start('read note', thread: 'durable.route.legacy', request_id: 'request.1')

      resumed_model = ScriptedModel.new
      resumed = build_session(
        model: resumed_model,
        root:,
        adapter:,
        routing: :experimental
      )

      view = resumed.view(thread: 'durable.route.legacy')

      assert_equal '1', view.state.fetch(:session).fetch('graph_version')
      refute_includes resumed.send(:app_for_thread, 'durable.route.legacy').definition.nodes.keys, :route
      assert_empty resumed_model.calls
    end
  end

  private

  def with_workspace
    Dir.mktmpdir('tamoz-durable-routing') do |directory|
      root = File.join(directory, 'workspace')
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, 'tamoz.sqlite3'),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def build_session(model:, root:, adapter:, **)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:),
      checkpointer: adapter,
      **
    )
  end

  def plan_for(tool, arguments, id: 'step')
    {
      'goal' => 'answer the task',
      'done_when' => ['the tool returned evidence'],
      'steps' => [{
        'id' => id,
        'purpose' => 'gather evidence',
        'tool' => tool,
        'arguments' => arguments,
        'verification' => 'the output is present'
      }]
    }
  end

  def accepted_review
    { 'decision' => 'accept', 'issues' => [], 'rationale' => 'sound' }
  end
end
