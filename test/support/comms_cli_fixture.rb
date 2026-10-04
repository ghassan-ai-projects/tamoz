# frozen_string_literal: true

module CommsCliFixture
  private

  def with_store(runtime)
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(runtime.dir, 'runtime.sqlite3'))
    definition = Tamoz.graph(name: 't', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 't.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    checkpoints = definition.compile(checkpointer: adapter).checkpointer
    yield adapter.bind_comms_store(checkpoints)
  ensure
    adapter&.close
  end

  def binding_wire
    Tamoz::Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      bound_at: Time.utc(2026, 8, 10, 12, 0, 0), bound_by: 'operator:test'
    ).wire
  end

  def conversation_wire
    Tamoz::Comms::Conversation.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      conversation_id: 'telegram:chat:22222222',
      thread_id: Tamoz::Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222'),
      profile_id: 'ops', bound_at: Time.utc(2026, 8, 10, 12, 0, 0)
    ).wire
  end

  def delivery_wire
    Tamoz::Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'hello',
      part_index: 0, part_count: 1, journaled: true,
      render_version: Tamoz::Comms::Rendering::RENDER_VERSION,
      content_digest: Tamoz::Comms::Rendering.content_digest('hello')
    ).wire
  end
end
