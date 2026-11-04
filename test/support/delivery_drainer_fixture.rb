# frozen_string_literal: true

require_relative '../test_helper'

module DeliveryDrainerFixture
  Comms = Tamoz::Comms

  class WorkingStore
    attr_accessor :working

    def initialize = @working = []
    def reconcile_expired_deliveries(now:) = now
    def outbox_rows(**) = []
    def working_conversations(**) = @working
  end

  class SignalTransport
    attr_reader :signals

    def initialize = @signals = []
    def signal(kind, conversation_id:) = @signals << [kind, conversation_id]
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

    def poll(next_offset:, **)
      { updates: [], next_offset: next_offset }
    end

    def deliver(delivery)
      @attempts << delivery
      raise Comms::AuthenticationError, 'bot credential refused' if @raise_auth
      raise Comms::AmbiguousDeliveryError, 'response beyond the declared cap' if @raise_too_large

      @deliveries << delivery
      { 'message_id' => @deliveries.length, 'date' => 1 }
    end
  end

  private

  def with_runtime
    Dir.mktmpdir('tamoz-drainer') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapters = Array.new(3) { Tamoz::SQLite::Adapter.new(path:) }
      begin
        yield(*runtime_arguments(*adapters))
      ensure
        adapters.reverse_each { |adapter| adapter.close unless adapter.closed? }
      end
    end
  end

  def runtime_arguments(main_adapter, drainer_adapter, second_adapter)
    checkpoints = drainer_graph.compile(checkpointer: main_adapter).checkpointer
    main_store = main_adapter.bind_comms_store(checkpoints)
    main_store.deploy_surface(descriptor.wire, now:)
    [main_adapter, drainer_adapter, main_store, drainer_adapter.bind_comms_store,
     second_adapter, second_adapter.bind_comms_store, checkpoints]
  end

  def drainer_graph
    Tamoz.graph(name: 'drainer-test', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 'drainer-test.finish', version: '1') { |_state, _context| {} }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def build_fence_losing_drainer(main_store, first_adapter, second_adapter, transport)
    row = main_store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
    second_store = second_adapter.bind_comms_store
    Tamoz::Comms::DeliveryDrainer.new(
      store: first_adapter.bind_comms_store,
      transport:,
      descriptor:,
      owner: 'drainer:paced',
      clock: -> { now },
      sleeper: lambda { |_seconds|
        second_store.claim_delivery(
          delivery_id: row.fetch('delivery_id'),
          lease: Tamoz::Comms::Lease.new(owner: 'drainer:taker', fence: 9).wire,
          claim_expires_at: now + 60, now: now + 31
        )
      }
    )
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
      kind: 'telegram',
      surface_id: 'telegram-ops', revision: 1,
      transport: {
        credential_ref: { kind: 'env', name: 'TOKEN' },
        poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144
      },
      identity: { stream_id: 'telegram:bot:7' }, settings: { bot_username: 'ops_bot' },
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
end
