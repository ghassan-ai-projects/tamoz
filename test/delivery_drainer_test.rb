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

  def test_a_stale_owner_runs_no_external_send_and_records_no_result_after_takeover
    with_runtime do |_main_adapter, first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('answer'), surface_id: 'telegram-ops', capacity: 10, now:)
      row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
      transport = ScriptedTransport.new
      stale = build_drainer(first_adapter, transport, 'drainer:stale')

      assert stale.send(:claim, row, now:), 'the drainer initially holds its own claim'
      taker_store = second_adapter.bind_comms_store
      assert_equal :not_claimable, taker_store.claim_delivery(
        delivery_id: row.fetch('delivery_id'), owner: 'drainer:taker', fence: 7,
        claim_expires_at: now + 60, now:
      ), 'a live unexpired claim is not stealable'
      assert_equal :claimed, taker_store.claim_delivery(
        delivery_id: row.fetch('delivery_id'), owner: 'drainer:taker', fence: 7,
        claim_expires_at: now + 60, now: now + 31
      )

      stale.send(:send_row, row, now:)

      assert_empty transport.deliveries, 'the stale owner must not cross the send boundary'
      held = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[claimed]).first

      assert_equal 'drainer:taker', held.fetch('claim_owner')
      assert_equal 7, held.fetch('claim_fence')
      assert_nil held.fetch('receipt'), 'the stale owner records no result'
    end
  end

  def test_a_fence_lost_between_claim_and_send_start_bars_the_external_send
    with_runtime do |_main_adapter, first_adapter, main_store, _first_store, second_adapter, _second_store, _checkpoints|
      main_store.append_delivery(delivery('paced'), surface_id: 'telegram-ops', capacity: 10, now:)
      main_store.reserve_delivery_slot(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:1',
        per_chat_messages_per_s: 1.0, global_messages_per_s: 25.0, now:
      )
      row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
      second_store = second_adapter.bind_comms_store
      transport = ScriptedTransport.new
      drainer = Tamoz::Comms::DeliveryDrainer.new(
        store: first_adapter.bind_comms_store,
        transport:,
        descriptor:,
        owner: 'drainer:paced',
        clock: -> { now },
        sleeper: lambda { |_seconds|
          second_store.claim_delivery(
            delivery_id: row.fetch('delivery_id'), owner: 'drainer:taker', fence: 9,
            claim_expires_at: now + 60, now: now + 31
          )
        }
      )

      assert_equal :drained, drainer.drain_once(now:)

      assert_empty transport.deliveries, 'no external send once the send-start fence was lost'
      held = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[claimed]).first

      assert_equal 'drainer:taker', held.fetch('claim_owner')
      assert_nil held.fetch('send_started_at_ms'), 'the stale owner marks nothing on the new owners row'
      assert_nil held.fetch('receipt')
    end
  end

  def test_mark_delivery_rejects_a_stale_owners_outcome_write
    with_runtime do |_main_adapter, _first_adapter, main_store, *_rest|
      main_store.append_delivery(delivery('answer'), surface_id: 'telegram-ops', capacity: 10, now:)
      row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
      delivery_id = row.fetch('delivery_id')
      main_store.claim_delivery(delivery_id:, owner: 'drainer:stale', fence: 3,
                                claim_expires_at: now + 1, now:)
      main_store.claim_delivery(delivery_id:, owner: 'drainer:current', fence: 4,
                                claim_expires_at: now + 60, now: now + 2)

      assert_equal :not_claimable, main_store.mark_delivery(
        delivery_id:, owner: 'drainer:stale', fence: 3,
        status: 'succeeded', receipt: { 'message_id' => 99 }, now: now + 3
      )
      held = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[claimed]).first

      assert_equal 'drainer:current', held.fetch('claim_owner')
      assert_equal 4, held.fetch('claim_fence')
      assert_nil held.fetch('receipt'), 'the losing write changes nothing'

      assert_equal :marked, main_store.mark_delivery(
        delivery_id:, owner: 'drainer:current', fence: 4,
        status: 'succeeded', receipt: { 'message_id' => 99 }, now: now + 3
      )
    end
  end

  def test_an_authentication_failure_fails_the_row_stops_the_drainer_and_spares_pending_rows
    with_runtime do |_main_adapter, first_adapter, main_store, *_rest|
      main_store.append_delivery(delivery('first'), surface_id: 'telegram-ops', capacity: 10, now:)
      main_store.append_delivery(delivery('second'), surface_id: 'telegram-ops', capacity: 10, now:)
      transport = ScriptedTransport.new
      transport.raise_auth = true
      drainer = build_drainer(first_adapter, transport, 'drainer:auth')

      assert_equal :authentication_refused, drainer.drain_once(now:)

      failed = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[failed])

      assert_equal ['first'], failed.map { |row| row.fetch('text') }
      assert_equal 'authentication_refused', JSON.parse(failed.first.fetch('receipt')).fetch('reason_code')
      pending = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal ['second'], pending.map { |row| row.fetch('text') }, 'unattempted rows stay pending'
      assert_equal ['first'], transport.attempts.map(&:text)
      assert_empty transport.deliveries, 'a refused credential delivers nothing'

      assert_equal :authentication_refused, drainer.serve_loop(interval_s: 0)
      assert_equal ['first', 'second'], transport.attempts.map(&:text)
      assert_equal 1, transport.attempts.count { |sent| sent.text == 'first' },
                   'a failed row is terminal and never resent'
    end
  end

  # A response abandoned past the declared byte cap may still have carried
  # the request to Telegram — the honest outcome is unknown, never a retry
  # and never a claimed success.
  def test_a_send_whose_response_exceeds_the_cap_is_unknown_not_retried
    with_runtime do |_main_adapter, first_adapter, main_store, *_rest|
      main_store.append_delivery(delivery('large'), surface_id: 'telegram-ops', capacity: 10, now:)
      transport = ScriptedTransport.new
      transport.raise_too_large = true
      drainer = build_drainer(first_adapter, transport, 'drainer:too-large')

      assert_equal :drained, drainer.drain_once(now:)

      assert_equal ['large'], transport.attempts.map(&:text)
      rows = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[unknown])

      assert_equal 1, rows.length, 'the unread response leaves the outcome honestly unknown'
      assert_nil rows.first.fetch('receipt')
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
    attr_reader :deliveries, :attempts
    attr_accessor :raise_auth, :raise_too_large

    def initialize
      @deliveries = []
      @attempts = []
      @raise_auth = false
      @raise_too_large = false
    end

    def poll(next_offset:, limit:, timeout_s:)
      { updates: [], next_offset: next_offset }
    end

    def deliver(delivery)
      @attempts << delivery
      raise Comms::AuthenticationError, 'bot credential refused' if @raise_auth
      raise Tamoz::Telegram::ResponseTooLargeError, 'response beyond the declared cap' if @raise_too_large

      @deliveries << delivery
      { 'message_id' => @deliveries.length, 'date' => 1 }
    end
  end
end
