# frozen_string_literal: true

require_relative 'session_edit_plans'

module SessionContextControlsHarness
  CONTROLS = Tamoz::Agent::SessionContextControls
  RECORDS = Tamoz::Agent::SessionRecords
  THREAD = 'thread.controls'
  SUMMARY_TEXT = 'The user asked to change the value; it is done.'
  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  CHECK_INCLUDES = 'abort("wrong") unless File.read("app.rb").include?("value = 2")'
  CHECK_EXACT = %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}
  COMPACT_INITIAL = [("#{'p' * 60}\n" * 300), "value = 1\n"].join

  class ScriptedModel
    include SessionEditPlans

    attr_reader :calls

    def initialize(digest, summary)
      @digest = digest
      @summary = summary
      @calls = []
    end

    def generate(stage:, prompt:, **)
      phase = begin
        JSON.parse(prompt)['phase']
      rescue StandardError
        nil
      end || 'verify'
      @calls << "#{stage}:#{phase}"
      case stage
      when :plan then JSON.generate(phase == 'discovery' ? discovery : action)
      when :review then JSON.generate('decision' => 'accept', 'issues' => [], 'rationale' => 'sound')
      when :context_compact then @summary
      else
        JSON.generate('answer' => 'value is 2', 'satisfied' => true, 'evidence' => ['app.rb'])
      end
    end
  end

  private

  def planning_context
    configuration = Struct.new(:memory, :memory_owner).new(nil, nil)
    Tamoz::Agent::SessionPlanningContext.new(configuration:, memory: nil)
  end

  def latest_state(session)
    session.app.state(thread: THREAD).state
  end

  def latest_tip(session)
    session.app.checkpointer.latest(thread_id: THREAD, namespace: [])
  end

  def control_count(session)
    tip = latest_tip(session)
    tip ? Array(tip.state[:context_controls]).length : 0
  end

  def complete_turn(session)
    session.start('set value to 2', thread: THREAD, request_id: 'r0')
    drive_to_completion(session)
  end

  def drive_to_completion(session, thread: THREAD)
    view = session.view(thread:)
    index = 0
    while index < 8 && !view.interrupts.empty?
      index += 1
      session.resume(
        { view.interrupts.first.task_id => { 0 => true } },
        thread:, request_id: "resume.#{index}"
      )
      view = session.view(thread:)
    end

    assert_equal :completed, view.status
  end

  def seed_workspace(directory, initial)
    workspace = File.join(directory, 'workspace')
    FileUtils.mkdir_p(workspace)
    File.write(File.join(workspace, 'app.rb'), initial)
    File.realpath(workspace)
  end

  def build_toolbox(workspace, check)
    Tamoz::Agent::Toolbox.new(
      root: workspace,
      allow_changes: true,
      checks: { 'answer' => [RbConfig.ruby, '-e', check] }
    )
  end

  def build_rig(directory, initial:, summary:, check:, tenant: nil)
    workspace = seed_workspace(directory, initial)
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'tamoz.sqlite3'))
    store = tenant && adapter.bind_artifact_store(tenant:)
    model = ScriptedModel.new(Digest::SHA256.hexdigest(initial), summary)
    session = Tamoz::Agent::Session.new(
      model:, toolbox: build_toolbox(workspace, check), checkpointer: adapter,
      artifact_store: store, artifact_tenant: tenant
    )
    { adapter:, session:, model:, store:, workspace: }
  end

  def with_session
    Dir.mktmpdir('tamoz-context-controls') do |directory|
      rig = build_rig(directory, initial: "value = 1\n", summary: '{"summary":"keep the goal"}', check: CHECK_EXACT)
      begin
        yield rig.fetch(:session), rig.fetch(:workspace)
      ensure
        rig.fetch(:adapter)&.close
      end
    end
  end

  def with_compact_session(tenant:, check:)
    Dir.mktmpdir('tamoz-context-compact') do |directory|
      summary = JSON.generate('summary' => SUMMARY_TEXT)
      rig = build_rig(directory, initial: COMPACT_INITIAL, summary:, check:, tenant:)
      begin
        yield rig.fetch(:session), rig.fetch(:model), rig.fetch(:store)
      ensure
        rig.fetch(:adapter)&.close
      end
    end
  end

  def enqueue_turn(checkpointer, request_id, task)
    checkpointer.enqueue_request(
      thread_id: THREAD, request_id:, operation: :turn,
      payload: { 'task' => task }, delivery: :queue
    )
  end

  def enqueue_turns(checkpointer, request_prefix, task_prefix, count)
    count.times { |index| enqueue_turn(checkpointer, "#{request_prefix}#{index}", "#{task_prefix}#{index}") }
  end
end
