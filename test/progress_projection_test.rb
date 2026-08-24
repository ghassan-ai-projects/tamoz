# frozen_string_literal: true

# Phase 2 work items 1-2 (plan 03): lifecycle milestones projected from
# committed worker facts onto the outbox, bounded and coalesced store-side.
# Rendering is a later wave; everything here asserts the SEAM.
#
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class ProgressProjectionTest < Minitest::Test
  include AutonomyCase

  Comms = Tamoz::Comms
  MILESTONE_KINDS = %w[running waiting progress].freeze
  WORKER_MILESTONE_EVENTS = %w[request.claimed request.running request.waiting request.recovered].freeze

  # ---------------------------------------------------------------- harness

  def with_engine
    Dir.mktmpdir('tamoz-progress') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'progress', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'progress.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        sink = Comms::OutboxDeliverySink.new(adapter:, checkpoints:)
        yield sink, adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  def descriptor(**overrides)
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990 },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 100, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 500, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 },
      **overrides
    )
  end

  def bind_thread_to_conversation(store, thread: 'tg.ops.abc')
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    store.deploy_surface(descriptor.wire, now:)
    store.bind_conversation(
      Comms::Conversation.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        conversation_id: 'telegram:chat:22222222', thread_id: thread,
        profile_id: 'ops', bound_at: now
      ).wire,
      now:
    )
    store.bind_correspondent(binding_wire(now), now:)
    envelope = Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id: 1,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      text: 'hello', observed_time: now
    ).wire
    store.admit_and_enqueue(
      envelope, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                thread:, profile_id: 'ops', reservation: 1, now:
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

  def milestone_event(kind, sequence:, phase:, request_id: 'occurrence-1', thread_id: 'tg.ops.abc')
    { thread_id:, kind:, text: nil, request_id:, sequence:, phase: }
  end

  def milestone_rows(store, request_ref = nil)
    store.outbox_rows(surface_id: 'telegram-ops',
                      statuses: %w[pending claimed succeeded failed unknown]).select do |row|
      next false unless row.fetch('kind') == 'control' && row.fetch('journaled') == 0 && row['markup']

      facts = JSON.parse(row.fetch('markup'))
      next false unless facts.is_a?(Hash) && facts['request_ref'].is_a?(String)

      request_ref.nil? || facts.fetch('request_ref') == request_ref
    end
  end

  # The full request id behind the conversation's active short reference.
  def admitted_request_id(store)
    status = store.conversation_status(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222')
    resolved = store.request_status(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
                                    ref: status.fetch('request_ref'))
    resolved.fetch('request_id')
  end

  def drain_row(store, delivery_id, now: Time.utc(2026, 8, 10, 12, 1, 0))
    assert_equal :claimed, store.claim_delivery(
      delivery_id:, owner: 'drainer', fence: 7, claim_expires_at: now + 30, now:
    )
    assert_equal :marked, store.mark_delivery_send_started(delivery_id:, owner: 'drainer', fence: 7, now:)
    assert_equal :marked, store.mark_delivery(
      delivery_id:, owner: 'drainer', fence: 7, status: 'succeeded',
      receipt: { 'message_id' => CARD_MESSAGE_ID }, now:
    )
  end

  def drain_row_without_receipt(store, delivery_id, now: Time.utc(2026, 8, 10, 12, 1, 0))
    assert_equal :claimed, store.claim_delivery(
      delivery_id:, owner: 'drainer', fence: 7, claim_expires_at: now + 30, now:
    )
    assert_equal :marked, store.mark_delivery_send_started(delivery_id:, owner: 'drainer', fence: 7, now:)
    assert_equal :marked, store.mark_delivery(
      delivery_id:, owner: 'drainer', fence: 7, status: 'failed', receipt: nil, now:
    )
  end

  # Plan 03 behavior model 1: the FIRST milestone for a request_ref renders
  # as an ordinary sendMessage card; while it is still pending the next
  # milestone coalesces into that one row (no second send); once its receipt
  # has bound a platform message id, every successor milestone is built as
  # edit_message targeting THAT id, read store-side from the receipt.
  def test_first_milestone_sends_a_card_and_receipt_bound_successors_edit_it
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed'))
      first = milestone_rows(store).first

      assert_equal 'send_message', first.fetch('operation')
      assert_nil first.fetch('reply_to'), 'the first card is a normal send'

      assert_equal :accepted, sink.push(milestone_event('request.waiting', sequence: 2, phase: 'waiting'))
      pending = milestone_rows(store)

      assert_equal 1, pending.length, 'no second send exists while the first card is pending'
      assert_equal 'send_message', pending.first.fetch('operation')

      drain_row(store, first.fetch('delivery_id'))

      assert_equal :accepted, sink.push(milestone_event('request.recovered', sequence: 3, phase: 'recovered'))
      successor = milestone_rows(store).find { |row| row.fetch('status') == 'pending' }

      assert_equal 'edit_message', successor.fetch('operation')
      assert_equal CARD_MESSAGE_ID, successor.fetch('reply_to'),
                   'the successor edits the receipt-bound live card'

      assert_equal :accepted, sink.push(milestone_event('request.running', sequence: 4, phase: 'action'))
      coalesced = milestone_rows(store).find { |row| row.fetch('status') == 'pending' }

      assert_equal successor.fetch('delivery_id'), coalesced.fetch('delivery_id'),
                   'successors still coalesce into the one live edit row'
      assert_equal CARD_MESSAGE_ID, coalesced.fetch('reply_to')
      assert_equal 4, JSON.parse(coalesced.fetch('markup')).fetch('sequence')
    end
  end

  # A request whose first card never got a delivery receipt keeps ordinary
  # sends: without a bound message there is nothing honest to edit.
  def test_successors_stay_sends_while_no_card_receipt_exists
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed'))
      drain_row_without_receipt(store, milestone_rows(store).first.fetch('delivery_id'))
      assert_equal :accepted, sink.push(milestone_event('request.waiting', sequence: 2, phase: 'waiting'))

      live = milestone_rows(store).find { |row| row.fetch('status') == 'pending' }

      assert_equal 'send_message', live.fetch('operation')
      assert_nil live.fetch('reply_to')
    end
  end

  REQUEST_REF = 'roccurrence'
  CARD_MESSAGE_ID = 42

  # ---------------------------------------------------------------- the seam

  def test_milestone_kinds_project_non_terminal_control_rows_with_the_full_projection
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed'))
      rows = milestone_rows(store)

      assert_equal 1, rows.length
      row = rows.first
      assert_equal 'control', row.fetch('kind')
      assert_equal 0, row.fetch('journaled'), 'milestones never journal into conversation history'
      markup = JSON.parse(row.fetch('markup'))
      assert_equal REQUEST_REF, markup.fetch('request_ref')
      assert_equal 'running', markup.fetch('milestone')
      assert_equal 'claimed', markup.fetch('phase')
      assert_equal 1, markup.fetch('sequence')
      assert_equal 'running', markup.fetch('task_state')
      assert_equal 'pending', markup.fetch('delivery_state')
      assert_match(/\A#{Regexp.escape(REQUEST_REF)}: claimed\z/, row.fetch('text'))
      assert_operator row.fetch('text').length, :<=, 200
    end
  end

  # The slow-request ladder at the seam: every committed fact projects in
  # order onto ONE live row, and the terminal projection lands after it.
  def test_slow_request_ladder_coalesces_milestones_then_projects_terminal_last
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      ladder = [
        ['request.claimed', 1, 'claimed'],
        ['request.waiting', 2, 'waiting'],
        ['request.recovered', 3, 'recovered'],
        ['request.running', 4, 'action']
      ]
      ladder.each do |kind, sequence, phase|
        assert_equal :accepted, sink.push(milestone_event(kind, sequence:, phase:))
      end

      rows = milestone_rows(store)
      assert_equal 1, rows.length, 'the whole ladder coalesces into one live row while pending'
      markup = JSON.parse(rows.first.fetch('markup'))
      assert_equal({ 'request_ref' => REQUEST_REF, 'milestone' => 'running', 'phase' => 'action',
                     'sequence' => 4, 'task_state' => 'running', 'delivery_state' => 'pending' },
                   markup)

      assert_equal :accepted, sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed',
                                        text: 'done', request_id: 'occurrence-1')
      kinds = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).map { |row| row.fetch('kind') }
      assert_equal ['control', 'answer'], kinds, 'the terminal projection lands after the live milestone row'
      terminal_kinds = Comms::OutboxDeliverySink::TERMINAL_KINDS
      assert_empty(terminal_kinds & MILESTONE_KINDS)
      assert_equal %w[answer failed stopped blocked], terminal_kinds
    end
  end

  def test_terminal_projection_releases_the_reservation_after_milestones
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)
      request_id = admitted_request_id(store)

      sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed', request_id:))
      sink.push(milestone_event('request.recovered', sequence: 2, phase: 'recovered', request_id:))
      status = store.conversation_status(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222')

      assert_equal 'accepted', status.fetch('state'), 'an open request stays admitted while milestones stream'
      assert_equal Comms::Lifecycle::RequestRef.for(request_id), status.fetch('request_ref')

      sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'done', request_id:)
      status = store.conversation_status(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222')

      assert_equal 'idle', status.fetch('state'), 'only the terminal projection releases the request'
    end
  end

  # Coalescing rule: a pending milestone row for the same request_ref is
  # UPDATED in place; once the drainer has claimed it, the next milestone
  # inserts a fresh row — a bounded stream, not an unbounded edit log.
  def test_pending_milestones_coalesce_in_place_and_post_claim_milestones_insert
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed'))
      first = milestone_rows(store).first
      first_id = first.fetch('delivery_id')

      assert_equal :accepted, sink.push(milestone_event('request.waiting', sequence: 2, phase: 'waiting'))
      rows = milestone_rows(store)

      assert_equal 1, rows.length, 'two milestones while pending are still ONE row'
      assert_equal first_id, rows.first.fetch('delivery_id'), 'the live row is updated, not replaced'
      assert_equal 2, JSON.parse(rows.first.fetch('markup')).fetch('sequence')
      assert_match(/waiting/, rows.first.fetch('text'))

      drain_row(store, first_id)

      assert_equal :accepted, sink.push(milestone_event('request.recovered', sequence: 3, phase: 'recovered'))
      rows = milestone_rows(store)

      assert_equal 2, rows.length, 'after the send crossed the boundary the next milestone inserts'
      live = rows.find { |row| row.fetch('status') == 'pending' }
      sent = rows.find { |row| row.fetch('status') == 'succeeded' }
      refute_equal first_id, live.fetch('delivery_id')
      assert_equal 3, JSON.parse(live.fetch('markup')).fetch('sequence')
      assert_equal 2, JSON.parse(sent.fetch('markup')).fetch('sequence')
    end
  end

  # Bound: past 32 milestone rows for one request reference, further
  # milestones REPLACE the newest row — count never grows past the bound,
  # even when a drainer keeps freeing slots between milestones.
  def test_a_hundred_milestones_never_exceed_the_per_request_bound
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      100.times do |index|
        sink.push(milestone_event('request.phase', sequence: index + 1, phase: "p#{index}"))
        live = milestone_rows(store).find { |row| row.fetch('status') == 'pending' }
        drain_row(store, live.fetch('delivery_id')) if live
      end

      rows = milestone_rows(store)

      assert_operator rows.length, :<=, milestone_bound, 'the bound holds under the 100-milestone stress'
      rows.each do |row|
        assert_equal 0, row.fetch('journaled')
      end
      sequences = rows.map { |row| JSON.parse(row.fetch('markup')).fetch('sequence') }

      assert_includes sequences, 100, 'the last fact landed on the live row'
      assert_equal sequences.max, 100
    end
  end

  def milestone_bound
    Tamoz::SQLite::CommsOutbox::MILESTONE_BOUND
  end

  # Invariant 11 with an explicit regression fence: progress/control rows
  # NEVER become model context, even when their send succeeded.
  def test_succeeded_progress_never_enters_conversation_history_but_terminal_does
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed'))
      milestone = milestone_rows(store).first
      drain_row(store, milestone.fetch('delivery_id'))

      sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'the verified answer',
                request_id: 'occurrence-1')
      answer = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                    .find { |row| row.fetch('kind') == 'answer' }
      drain_row(store, answer.fetch('delivery_id'))

      history = store.conversation_history(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222')

      assert history.any? { |entry| entry.fetch('role') == 'assistant' &&
                                       entry.fetch('text').include?('the verified answer') },
             'the positive control proves the history query ran and terminal output enters'
      refute history.any? { |entry| entry.fetch('text').include?(REQUEST_REF) },
             'a succeeded milestone must never become model context'
      refute history.any? { |entry| entry.fetch('text').include?('claimed') }
    end
  end

  def test_unbound_threads_and_unknown_kinds_stay_nil_safe
    with_engine do |sink, adapter, _checkpoints|
      store = adapter.bind_comms_store(_checkpoints)
      bind_thread_to_conversation(store)

      assert_nil sink.push(milestone_event('request.claimed', sequence: 1, phase: 'claimed',
                                           thread_id: 'tg.unbound'))
      assert_nil sink.push(milestone_event('internal.noise', sequence: 1, phase: 'x'))
      assert_empty milestone_rows(store)
    end
  end

  # ------------------------------------------------------- worker emissions

  # A recording tee over the real outbox sink: assertions see exactly what
  # the worker pushed, while the channel projection still runs for real.
  class RecordingSink
    attr_reader :pushed

    def initialize(inner)
      @inner = inner
      @pushed = []
    end

    def push(event)
      @pushed << event
      @inner.push(event)
    end
  end

  def with_channel_worker(rt, factory:)
    directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
    runtime = Tamoz::Agent::WorkerRuntime.open(directory, model_factory: factory)
    begin
      store = runtime.adapter.bind_comms_store(runtime.checkpoints)
      bind_thread_to_conversation(store)
      runtime.bind_thread_profile('tg.ops.abc', 'trusted')
      runtime.instance_variable_set(
        :@delivery_sink,
        RecordingSink.new(Comms::OutboxDeliverySink.new(adapter: runtime.adapter,
                                                        checkpoints: runtime.checkpoints))
      )
      worker = Tamoz::Agent::Worker.new(
        runtime:, session_builder: ->(thread_id) { runtime.session_for(thread_id) },
        emitter: ->(_event) {}, once: true
      )
      yield runtime, worker, store
    ensure
      runtime&.close
    end
  end

  def recorded_milestones(runtime)
    runtime.delivery_sink.pushed.select { |event| WORKER_MILESTONE_EVENTS.include?(event.fetch(:kind)) }
  end

  def test_a_completed_request_emits_its_claim_milestone_at_the_commit_point
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      with_channel_worker(rt, factory: read_only_factory) do |runtime, worker, store|
        rt.cli(%W[queue add --task Read\ note.txt --thread tg.ops.abc], factory: read_only_factory)

        assert worker.poll_once

        milestones = recorded_milestones(runtime)
        assert_equal ['request.claimed'], milestones.map { |event| event.fetch(:kind) }
        assert_equal 1, milestones.first.fetch(:sequence)
        assert_equal 'claimed', milestones.first.fetch(:phase)

        request_id = milestones.first.fetch(:request_id)
        rows = milestone_rows(store, Comms::Lifecycle::RequestRef.for(request_id))

        assert_equal 1, rows.length
        assert_equal 0, rows.first.fetch('journaled')
        view = runtime.session_for('tg.ops.abc').view(thread: 'tg.ops.abc')

        assert_equal :completed, view.status
      end
    end
  end

  def test_recovery_emits_its_milestone_from_the_committed_recovery_fact
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      with_channel_worker(rt, factory: crashing_factory(after: :claim)) do |runtime, _worker, _store|
        rt.cli(%W[queue add --task Read\ note.txt --thread tg.ops.abc], factory: read_only_factory)

        assert_raises(CrashingModel::Killed) { _worker.poll_once }

        claimed = recorded_milestones(runtime).find { |event| event.fetch(:kind) == 'request.claimed' }

        refute_nil claimed

        second_directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
        second_runtime = Tamoz::Agent::WorkerRuntime.open(second_directory, model_factory: read_only_factory)
        begin
          second_runtime.instance_variable_set(
            :@delivery_sink,
            RecordingSink.new(Comms::OutboxDeliverySink.new(adapter: second_runtime.adapter,
                                                            checkpoints: second_runtime.checkpoints))
          )
          second_worker = Tamoz::Agent::Worker.new(
            runtime: second_runtime,
            session_builder: ->(thread_id) { second_runtime.session_for(thread_id) },
            emitter: ->(_event) {}, once: true
          )

          assert second_worker.poll_once

          recovered = recorded_milestones(second_runtime)
                      .find { |event| event.fetch(:kind) == 'request.recovered' }

          refute_nil recovered, 'the recovery commit point must project its milestone'
          assert_equal 'recovered', recovered.fetch(:phase)
          assert_equal claimed.fetch(:request_id), recovered.fetch(:request_id),
                       'recovery projects against the SAME occurrence that was lost'
          view = second_runtime.session_for('tg.ops.abc').view(thread: 'tg.ops.abc')

          assert_equal :completed, view.status
        ensure
          second_runtime&.close
        end
      end
    end
  end

  def test_an_approval_pause_emits_waiting_before_the_prompt
    with_runtime(approval_profile: 'unattended') do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      with_channel_worker(rt, factory: edit_factory) do |runtime, worker, store|
        rt.cli(%W[queue add --task Fix\ note.txt --thread tg.ops.abc --profile trusted],
               factory: edit_factory)

        worker.poll_once

        kinds = recorded_milestones(runtime).map { |event| event.fetch(:kind) }

        assert_includes kinds, 'request.waiting'
        waiting = recorded_milestones(runtime).find { |event| event.fetch(:kind) == 'request.waiting' }

        assert_equal 'waiting', waiting.fetch(:phase)
        prompt = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                      .find { |row| row.fetch('kind') == 'approval_request' }

        refute_nil prompt, 'the approval pause still projects its actionable prompt'
      end
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
