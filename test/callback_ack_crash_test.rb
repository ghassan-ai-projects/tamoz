# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'

# Phase 2 work item 6 (plan 03), the study's flagged-missing coverage: a
# Telegram callback is acknowledged immediately after its durable admission
# record and before any turn processing, and the prompt activation plus the
# decision survive a worker crash boundary.
#
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
class CallbackAckCrashTest < Minitest::Test
  include AutonomyCase

  Comms = Tamoz::Comms
  THREAD_ID = 'tg.ops.abc'
  SURFACE_ID = 'telegram-ops'
  CONVERSATION_ID = 'telegram:chat:22222222'
  BOT_ID = 7_463_512_990

  # ---------------------------------------------------------------- harness

  def descriptor
    @descriptor ||= Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 100, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 500, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def bind_thread_to_conversation(store, now:)
    store.deploy_surface(descriptor.wire, now:)
    store.bind_conversation(
      Comms::Conversation.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        conversation_id: CONVERSATION_ID, thread_id: THREAD_ID,
        profile_id: 'ops', bound_at: now
      ).wire,
      now:
    )
    store.bind_correspondent(
      Comms::Binding.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        correspondent_id: 'telegram:user:11111111',
        conversation_id: CONVERSATION_ID,
        bound_at: now, bound_by: 'operator:test'
      ).wire,
      now:
    )
    envelope = Comms::InboundEnvelope.new(
      surface_id: SURFACE_ID, surface_revision: 1, update_id: 1,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111',
      conversation_id: CONVERSATION_ID,
      text: 'hello', observed_time: now
    ).wire
    store.admit_and_enqueue(
      envelope, surface_id: SURFACE_ID, bot_id: BOT_ID,
                thread: THREAD_ID, profile_id: 'ops', reservation: 1, now:
    )
  end

  def with_channel_runtime(factory:)
    directory = Tamoz::Agent::RuntimeDirectory.resolve(path: @runtime_dir, env: {})
    runtime = Tamoz::Agent::WorkerRuntime.open(directory, model_factory: factory)
    begin
      runtime.instance_variable_set(
        :@delivery_sink, Comms::OutboxDeliverySink.new(adapter: runtime.adapter,
                                                       checkpoints: runtime.checkpoints)
      )
      yield runtime, runtime.adapter.bind_comms_store(runtime.checkpoints)
    ensure
      runtime&.close
    end
  end

  def new_worker(runtime)
    Tamoz::Agent::Worker.new(
      runtime:, session_builder: ->(thread_id) { runtime.session_for(thread_id) },
      emitter: ->(_event) {}, once: true
    )
  end

  def approval_interrupts
    [{ task_id: 't1', call_index: 0,
       descriptor: { 'kind' => 'approve_tool', 'decision' => { 'required_evidence' => 'chat_bound' } } }]
  end

  def callback_wire(update_id:, callback_id:, reference:, callback_message_id:, direction: 'deny')
    Tamoz::Telegram::Normalizer.new(surface_id: SURFACE_ID, surface_revision: 1).normalize(
      { 'update_id' => update_id,
        'callback_query' => { 'id' => callback_id, 'data' => "#{direction}:#{reference}",
                              'from' => { 'id' => 11_111_111 },
                              'message' => { 'message_id' => callback_message_id, 'date' => 1_752_700_800,
                                             'chat' => { 'id' => 22_222_222, 'type' => 'private' } } } }
    ).wire
  end

  def pending_prompt_row(store)
    row = store.outbox_rows(surface_id: SURFACE_ID, statuses: %w[pending])
               .find { |candidate| candidate.fetch('kind') == 'approval_request' }
    refute_nil row, 'the pause projects its actionable prompt'
    JSON.parse(row.fetch('markup')).fetch('reference')
  end

  def activate_prompt(store, transport, reference, now:)
    drainer = Comms::DeliveryDrainer.new(store:, transport:, descriptor:, owner: 'test:drainer',
                                         sleeper: ->(_seconds) {})
    assert_equal :drained, drainer.drain_once(now:)

    digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
    prompt = store.prompt(reference_digest: digest)
    assert_equal 'active', prompt.fetch('status'), 'the delivered card activates the prompt durably'
    [digest, prompt]
  end

  def dispositions(store, update_id)
    store.__send__(:read, operation: 'test.callback.dispositions') do |txn|
      txn.rows('test.callback.dispositions',
               'SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?', [update_id])
    end
  end

  def decision_rows(adapter)
    adapter.__send__(:read, operation: 'test.callback.decisions') do |txn|
      txn.rows('test.callback.decisions',
               'SELECT direction, status FROM tamoz_comms_decisions ORDER BY decided_at_ms')
    end
  end

  def request_count(adapter, thread_id)
    adapter.__send__(:read, operation: 'test.callback.requests') do |txn|
      txn.scalar('test.callback.requests',
                 'SELECT COUNT(*) FROM tamoz_requests WHERE thread_id = ?', [thread_id]).to_i
    end
  end

  # A transport that records every acknowledgement, and can crash its sends,
  # so everything a serve pass would do after admission dies mid-pass.
  class RecordingTransport
    attr_reader :acks
    attr_accessor(:crash_deliveries)

    def initialize
      @updates = []
      @acks = []
      @last_message_id = 100
      @crash_deliveries = false
    end

    def batch(wires)
      @updates = wires
    end

    def poll(next_offset:, limit:, timeout_s:) # rubocop:disable Lint/UnusedMethodArgument
      ids = @updates.map { |wire| wire.fetch('update_id') }
      { updates: @updates, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(delivery)
      raise Comms::CommsError, 'fixture drain crash' if @crash_deliveries

      @last_message_id += 1
      { 'message_id' => @last_message_id, 'date' => 1_752_700_800 }
    end

    def signal(kind, **fields)
      return :unsupported unless kind == :ack

      @acks << fields.fetch(:callback_query_id)
      :acked
    end
  end

  # ------------------------------------------------------------- the proofs

  # The full chain across one worker crash boundary: the pause projects its
  # prompt, the drainer's receipt ACTIVATES it, the gateway admits the press
  # (durable disposition), acknowledges it, and enqueues NOTHING; the process
  # then dies before the turn is activated. After a restart the durable
  # decision resumes the same occurrence to completion.
  def test_callback_ack_precedes_the_turn_and_the_decision_survives_a_worker_restart
    base = Time.now.utc
    with_runtime(approval_profile: 'unattended') do |rt|
      @runtime_dir = rt.dir
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")

      with_channel_runtime(factory: edit_factory) do |runtime, store|
        bind_thread_to_conversation(store, now: base - 120)
        runtime.bind_thread_profile(THREAD_ID, 'trusted')

        rt.cli(%W[queue add --task Fix\ note.txt --thread #{THREAD_ID} --profile trusted],
               factory: edit_factory)

        worker = new_worker(runtime)
        worker.poll_once

        assert_equal :paused, runtime.session_for(THREAD_ID).view(thread: THREAD_ID).status

        reference = pending_prompt_row(store)
        transport = RecordingTransport.new
        digest, prompt = activate_prompt(store, transport, reference, now: base - 60)

        requests_before_ack = request_count(runtime.adapter, THREAD_ID)
        transport.batch([callback_wire(update_id: 9, callback_id: 'cbq-77', reference: reference,
                                       callback_message_id: Integer(prompt.fetch('prompt_receipt')))])
        gateway = Comms::Gateway.new(adapter: runtime.adapter, checkpoints: runtime.checkpoints,
                                     transport:, descriptor:, poller_owner: 'gateway:test')

        assert_equal :served, gateway.serve_once(now: base, drain: false)

        assert_equal ['cbq-77'], transport.acks, 'the press is acknowledged exactly once'
        assert_equal [%w[decision consumed]], dispositions(store, 9),
                     'the admission disposition is durable before anything else runs'
        assert_equal 'consumed', store.prompt(reference_digest: digest).fetch('status')
        # The real engine pins filesystem_operator evidence on this pause, so
        # the chat-bound press can only ever resolve as a deny (ADR-049 INV-B).
        assert_equal [%w[deny pending]], decision_rows(runtime.adapter)
        assert_equal requests_before_ack, request_count(runtime.adapter, THREAD_ID),
                     'the ack pass enqueues no resulting turn — the resume happens strictly later'
      end

      # The restart boundary: the first process is gone. The restarted worker
      # finds the durable deny against the SAME pause, applies it, and the
      # occurrence settles to its terminal projection.
      with_channel_runtime(factory: edit_factory) do |restarted, _store|
        new_worker(restarted).poll_once

        view = restarted.session_for(THREAD_ID).view(thread: THREAD_ID)

        assert_equal :completed, view.status,
                     'the durable decision carries the restarted turn to its terminal state'
        assert_equal [%w[deny consumed]], decision_rows(restarted.adapter),
                     'the decision survives the crash boundary and is applied exactly once'
      end
    end
  end

  # Crash-ordering at the gateway itself: everything the pass would do after
  # admission dies (the drain crashes), yet the acknowledgement already
  # happened, because it follows only the durable disposition record.
  def test_ack_lands_even_when_everything_after_admission_crashes
    Dir.mktmpdir('tamoz-callback-ack') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      base = Time.now.utc
      begin
        definition = Tamoz.graph(name: 'callback-ack', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'callback-ack.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        bind_thread_to_conversation(store, now: base - 120)

        sink = Comms::OutboxDeliverySink.new(adapter:, checkpoints:)
        assert_equal :accepted, sink.push(
          thread_id: THREAD_ID, kind: 'request.approval_request', text: 'Approval requested.',
          request_id: 'occurrence-1', interrupts: approval_interrupts
        )
        reference = pending_prompt_row(store)

        transport = RecordingTransport.new
        digest, prompt = activate_prompt(store, transport, reference, now: base - 60)

        drainer = Comms::DeliveryDrainer.new(store:, transport:, descriptor:, owner: 'test:drainer',
                                             sleeper: ->(_seconds) {})
        transport.crash_deliveries = true
        store.append_delivery(
          Comms::Delivery.build(
            conversation_id: CONVERSATION_ID, kind: 'control', text: 'later news',
            part_index: 0, part_count: 1, journaled: false,
            render_version: Comms::Rendering::RENDER_VERSION,
            content_digest: Comms::Rendering.content_digest('later news')
          ).wire,
          surface_id: SURFACE_ID, capacity: 50, now: base - 30
        )
        transport.batch([callback_wire(update_id: 9, callback_id: 'cbq-88', reference: reference,
                                       callback_message_id: Integer(prompt.fetch('prompt_receipt')))])
        gateway = Comms::Gateway.new(adapter:, checkpoints:, transport:, descriptor:,
                                     poller_owner: 'gateway:test', drainer:)

        assert_equal :transient, gateway.serve_once(now: base),
                     'the drain crashed the rest of the pass'

        assert_equal ['cbq-88'], transport.acks,
                     'the acknowledgement precedes everything the crashed pass had left to do'
        assert_equal [%w[decision consumed]], dispositions(store, 9)
        assert_equal 'consumed', store.prompt(reference_digest: digest).fetch('status'),
                     'the decision is durable even though the pass never finished'
      ensure
        adapter&.close
      end
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
