# frozen_string_literal: true

module ProfileSessionFixture
  private

  def recording_factory(sink)
    lambda do |options|
      model = read_factory.call(options)
      model.singleton_class.prepend(Module.new do
        define_method(:generate) do |stage:, system:, prompt:|
          sink << prompt if stage == :plan
          super(stage:, system:, prompt:)
        end
      end)
      model
    end
  end

  def read_factory
    lambda do |_options|
      self.class::ScriptedModel.new(
        plan: [plan_for('read_file', { 'path' => 'note.txt' })],
        review: [accepted_review],
        verify: [{ 'answer' => 'hello', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
    end
  end

  def accepted_review
    { 'decision' => 'accept', 'issues' => [], 'rationale' => 'the plan is minimal and read-only' }
  end

  def session_record(session_dir, thread_id)
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(session_dir, "#{thread_id}.sqlite3"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
    )
    dummy = Object.new
    def dummy.generate(**) = '{}'
    toolbox = Tamoz::Agent::Toolbox.new(root: Dir.tmpdir)
    session = Tamoz::Agent::Session.new(model: dummy, toolbox:, checkpointer: adapter)
    session.view(thread: thread_id).state.fetch(:session)
  ensure
    adapter&.close
  end
end
