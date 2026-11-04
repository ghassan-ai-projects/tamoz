# frozen_string_literal: true

module OutboxSinkFixtures
  Comms = Tamoz::Comms

  def with_engine
    Dir.mktmpdir('tamoz-sink') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'sink', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'sink.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        sink = Tamoz::Comms::OutboxDeliverySink.new(adapter:, checkpoints:)
        yield sink, adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  def store_for(adapter, checkpoints)
    adapter.bind_comms_store(checkpoints)
  end

  def descriptor(**overrides)
    Comms::SurfaceDescriptor.build(
      kind: 'telegram',
      surface_id: 'telegram-ops', revision: 1,
      transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { stream_id: 'telegram:bot:7463512990' },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 100, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 },
      **overrides
    )
  end

  def bind_thread_to_conversation(store, thread: 'telegram.ops.abc', surface: descriptor)
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    store.deploy_surface(surface.wire, now:)
    store.bind_correspondent(binding_wire(now), now:)
    envelope = Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id: 1,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      text: 'hello', observed_time: now
    ).wire
    store.admit_and_enqueue(
      envelope, stream_id: 'telegram:bot:7463512990',
                turn: Tamoz::Comms::Turn.new(thread:, profile_id: 'ops', reservation: 1).wire, now:
    )
  end

  def binding_wire(now)
    Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      bound_at: now, bound_by: 'operator:test'
    ).wire
  end
end
