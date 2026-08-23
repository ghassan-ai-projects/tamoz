# frozen_string_literal: true

require_relative 'test_helper'

class DeliveryDrainerTest < Minitest::Test
  Comms = Tamoz::Comms

  def test_polling_and_delivery_use_separate_store_and_transport_lifecycles
    with_runtime do |main_adapter, drainer_adapter, main_store, _drainer_store, _second_adapter, _second_store, checkpoints|
      main_store.append_delivery(delivery('answer'), surface_id: 'telegram-ops', capacity: 10, now: now)
      poll_transport = ScriptedTransport.new
      send_transport = ScriptedTransport.new
      drainer = Tamoz::Comms::DeliveryDrainer.new(
        store: drainer_adapter.bind_comms_store,
        transport: send_transport,
        descriptor: descriptor,
        owner: 'drainer:test',
        clock: -> { now },
        sleeper: ->(_seconds) {}
      )
      gateway = Tamoz::Comms::Gateway.new(
        adapter: main_adapter,
        checkpoints:,
        transport: poll_transport,
        descriptor:,
        poller_owner: 'gateway:test',
        drainer:
      )

      assert_equal :served, gateway.serve_once(drain: false)
      assert_empty poll_transport.deliveries
      assert_empty send_transport.deliveries

      assert_equal :drained, drainer.drain_once(now:)
      assert_equal 1, send_transport.deliveries.length
      assert_equal 1, main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded]).length
    end
  end

  def test_two_drainers_race_one_claim_and_one_transport_send
    with_runtime do |_main_adapter, first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('answer'), surface_id: 'telegram-ops', capacity: 10, now:)
      first_transport = ScriptedTransport.new
      second_transport = ScriptedTransport.new
      first = build_drainer(first_adapter, first_transport, 'drainer:first')
      second = build_drainer(second_adapter, second_transport, 'drainer:second')

      threads = [first, second].map { |drainer| Thread.new { drainer.drain_once(now:) } }
      threads.each(&:join)

      assert_equal 1, first_transport.deliveries.length + second_transport.deliveries.length
      assert_equal 1, main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded]).length
    end
  end

  def test_rate_limit_reservation_survives_a_drainer_restart
    with_runtime do |_main_adapter, first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('first'), surface_id: 'telegram-ops', capacity: 10, now:)
      first_sleeps = []
      first = build_drainer(
        first_adapter,
        ScriptedTransport.new,
        'drainer:first',
        sleeps: first_sleeps
      )
      first.drain_once(now:)

      main_store.append_delivery(delivery('second'), surface_id: 'telegram-ops', capacity: 10, now:)
      restart_sleeps = []
      restarted = build_drainer(
        second_adapter,
        ScriptedTransport.new,
        'drainer:restart',
        sleeps: restart_sleeps
      )
      restarted.drain_once(now:)

      assert_in_delta(1.0, restart_sleeps.first)
    end
  end

  def test_crashed_claim_is_retried_only_before_the_send_boundary
    with_runtime do |_main_adapter, _first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('retry'), surface_id: 'telegram-ops', capacity: 10, now:)
      row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first

      assert_equal :claimed, main_store.claim_delivery(
        delivery_id: row.fetch('delivery_id'), owner: 'crashed', fence: 1,
        claim_expires_at: now + 1, now:
      )

      transport = ScriptedTransport.new
      build_drainer(second_adapter, transport, 'drainer:restart').drain_once(now: now + 2)

      assert_equal 1, transport.deliveries.length
      assert_equal 1, main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded]).length
    end
  end

  def test_crashed_send_boundary_becomes_unknown_without_a_retry
    with_runtime do |_main_adapter, _first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('ambiguous'), surface_id: 'telegram-ops', capacity: 10, now:)
      row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
      main_store.claim_delivery(
        delivery_id: row.fetch('delivery_id'), owner: 'crashed', fence: 1,
        claim_expires_at: now + 1, now:
      )
      main_store.mark_delivery_send_started(
        delivery_id: row.fetch('delivery_id'), owner: 'crashed', fence: 1, now:
      )

      transport = ScriptedTransport.new
      build_drainer(second_adapter, transport, 'drainer:restart').drain_once(now: now + 2)

      assert_empty transport.deliveries
      assert_equal 1, main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[unknown]).length
    end
  end

  private

  def with_runtime
    Dir.mktmpdir('tamoz-drainer') do |directory|
      main_adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      drainer_adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      second_adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        definition = Tamoz.graph(name: 'drainer-test', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'drainer-test.finish', version: '1') { |_state, _context| {} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: main_adapter).checkpointer
        main_store = main_adapter.bind_comms_store(checkpoints)
        drainer_store = drainer_adapter.bind_comms_store
        second_store = second_adapter.bind_comms_store
        main_store.deploy_surface(descriptor.wire, now:)
        yield main_adapter, drainer_adapter, main_store, drainer_store, second_adapter, second_store, checkpoints
      ensure
        second_adapter.close unless second_adapter.closed?
        drainer_adapter.close unless drainer_adapter.closed?
        main_adapter.close unless main_adapter.closed?
      end
    end
  end

  def build_drainer(adapter, transport, owner, sleeps: [])
    Tamoz::Comms::DeliveryDrainer.new(
      store: adapter.bind_comms_store,
      transport:,
      descriptor:,
      owner:,
      clock: -> { now },
      sleeper: ->(seconds) { sleeps << seconds }
    )
  end

  def descriptor
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: {
        mode: 'long_poll',
        credential_ref: { kind: 'env', name: 'TOKEN' },
        poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144
      },
      identity: { expected_bot_id: 7, bot_username: 'ops_bot' },
      admission: { direct: 'disabled' }, threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'none', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: {
        max_inbound_bytes: 8192, max_open_requests: 50,
        max_denial_prompts_per_request: 4, outbox_capacity: 500, control_capacity: 50,
        per_chat_messages_per_s: 1.0, global_messages_per_s: 25.0
      }
    )
  end

  def delivery(text)
    Comms::Delivery.build(
      conversation_id: 'telegram:chat:1', kind: 'answer', text:,
      render_version: 1, content_digest: Digest::SHA256.hexdigest(text)
    ).wire
  end

  def now
    Time.utc(2026, 8, 11, 12, 0, 0)
  end

  class ScriptedTransport
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def poll(next_offset:, limit:, timeout_s:)
      { updates: [], next_offset: next_offset }
    end

    def deliver(delivery)
      @deliveries << delivery
      { 'message_id' => @deliveries.length, 'date' => 1 }
    end
  end
end
