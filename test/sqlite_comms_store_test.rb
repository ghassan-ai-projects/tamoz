# frozen_string_literal: true

require_relative 'test_helper'

# Slice C (COMMS_TELEGRAM_PLAN §3) — the CommsStore over SQLite (design §13).
# Every proof is behavioral: real SQLite, the real inbox enqueue seam, restart
# via a fresh adapter over the same file. The atomicity seams under test:
# admission shares the enqueue transaction (a replay dedups), prompt
# consumption inserts its decision in the same transaction (ADR-043), the
# poll offset never regresses, and the outbox is bounded and single-claim.
#
# Each case walks one primitive's whole state machine; the assertions belong
# to the same scenario.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength, Metrics/ClassLength
class SQLiteCommsStoreTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_engine
    Dir.mktmpdir('tamoz-comms') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'comms', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'comms.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        yield store, adapter, checkpoints, path
      ensure
        adapter&.close
      end
    end
  end

  def now = Time.utc(2026, 8, 10, 12, 0, 0)

  def descriptor(limits: {}, **overrides)
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1, transport: {
                                                 mode: 'long_poll',
                                                 credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                                                 poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144
                                               },
      identity: { expected_bot_id: 7_463_512_990 },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }.merge(limits),
      **overrides
    )
  end

  def envelope(update_id: 12_345, text: 'hello', **overrides)
    Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id:,
      raw_payload_hash: format('%064x', update_id), parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      message_id: update_id + 10_000, text:, observed_time: now, **overrides
    ).wire
  end

  def inbound_dispositions(store, update_id)
    store.__send__(:read, 'test.inbound.read') do |txn|
      txn.rows('test.inbound.read', <<~SQL, [update_id])
        SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?
      SQL
    end
  end

  def inbound_anchor_rows(store, update_id)
    rows = store.__send__(:read, 'test.inbound.anchor') do |txn|
      txn.rows('test.inbound.anchor', <<~SQL, [update_id])
        SELECT raw_payload_hash, conflict_count, last_conflict_digest,
               disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?
      SQL
    end
    rows.map do |hash, count, last, disposition, reason|
      { 'raw_payload_hash' => hash, 'conflict_count' => count,
        'last_conflict_digest' => last, 'disposition' => disposition, 'reason' => reason }
    end
  end

  def request_row_count(store)
    store.__send__(:read, 'test.request.count') do |txn|
      txn.scalar('test.request.count', 'SELECT COUNT(*) FROM tamoz_comms_requests').to_i
    end
  end

  def request_ids(checkpoints, thread)
    checkpoints.request_history(thread_id: thread).map(&:request_id)
  end

  def bind_route!(store, thread: 'tg.ops.abc', conversation_id: 'telegram:chat:22222222')
    store.bind_conversation(
      Comms::Conversation.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        conversation_id:, thread_id: thread,
        profile_id: 'ops', bound_at: now
      ).wire, now:
    )
  end

  def insert_request!(store, request_id:, conversation_id:, created_at_ms:, thread: 'tg.ops.abc')
    store.__send__(:transaction, 'test.request.insert') do |tx|
      binds = [request_id, 'telegram-ops', 1, conversation_id, thread, 'ops', 1, 'admitted', created_at_ms, created_at_ms]
      tx.execute('test.request.insert', <<~SQL, binds)
        INSERT INTO tamoz_comms_requests (
          request_id, surface_id, surface_revision, conversation_id,
          thread_id, profile_id, reservation, projection_state,
          created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
  end

  def admit(store, wire, thread: 'tg.ops.abc', now: self.now)
    store.admit_and_enqueue(
      wire, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
            thread:, profile_id: 'ops', reservation: 1, now:
    )
  end

  def delivery(**overrides)
    Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'ok',
      part_index: 0, part_count: 1, journaled: true, render_version: 1,
      content_digest: 'b' * 64, **overrides
    ).wire
  end

  def prompt_wire(reference:, status: 'inactive', expires_at: now + 900, thread: 'tg.ops.abc',
                  required_evidence: 'filesystem_operator')
    {
      'reference_digest' => reference, 'surface_id' => 'telegram-ops',
      'surface_revision' => 1, 'thread_id' => thread, 'occurrence_id' => 'req-1',
      'interrupt_digest' => 'c' * 64, 'required_evidence' => required_evidence,
      'correspondent_id' => 'telegram:user:11111111',
      'conversation_id' => 'telegram:chat:22222222', 'prompt_receipt' => 'msg-1',
      'status' => status, 'created_at' => now.iso8601(6),
      'activated_at' => status == 'active' ? now.iso8601(6) : nil,
      'consumed_at' => nil, 'expires_at' => expires_at.iso8601(6)
    }
  end

  def insert_prompt!(store, reference:, status: 'inactive', expires_at: now + 900)
    store.__send__(:transaction, 'test.prompt.insert') do |tx|
      tx.execute('test.prompt.insert', <<~SQL, prompt_binds(prompt_wire(reference:, status:, expires_at:)))
        INSERT INTO tamoz_comms_approval_prompts (
          reference_digest, surface_id, surface_revision, thread_id,
          occurrence_id, interrupt_digest, required_evidence,
          correspondent_id, conversation_id, prompt_receipt, status,
          created_at_ms, activated_at_ms, consumed_at_ms, expires_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
  end

  # MIG-9 (ADR-049 INV-C): the prompt pins its required_evidence and the
  # column round-trips through the store — a prompt always carries the
  # requirement it was built with.
  def test_a_prompt_round_trips_its_required_evidence_through_the_store
    with_engine do |store, adapter, _checkpoints, _path|
      store.insert_prompt(prompt_wire(reference: 'a' * 64, required_evidence: 'chat_bound'))

      row = store.prompt(reference_digest: 'a' * 64)

      refute_nil row, 'the prompt row must be readable'
      assert_equal 'chat_bound', row.fetch('required_evidence')
      refute_nil adapter
    end
  end

  def prompt_binds(wire)
    [
      wire.fetch('reference_digest'), wire['surface_id'], wire['surface_revision'],
      wire.fetch('thread_id'), wire.fetch('occurrence_id'), wire.fetch('interrupt_digest'),
      wire.fetch('required_evidence'),
      wire.fetch('correspondent_id'), wire.fetch('conversation_id'), wire['prompt_receipt'],
      wire.fetch('status'), ms(wire.fetch('created_at')), ms(wire['activated_at']),
      ms(wire['consumed_at']), ms(wire.fetch('expires_at'))
    ]
  end

  def ms(value)
    value && (Time.parse(value).utc.to_r * 1000).to_i
  end

  def decision_wire(direction: 'deny')
    Comms::DecisionRecord.build(
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      direction:, actor_kind: 'telegram_user', actor_id: 'telegram:user:11111111',
      source: 'telegram', decided_at: now
    ).wire
  end

  def test_contract_version_pairs_with_the_contract_gem
    assert_equal Comms::CommsStore::CONTRACT_VERSION, Tamoz::SQLite::CommsStore::CONTRACT_VERSION
  end

  def test_deploy_surface_is_upsert_and_digest_addressed
    with_engine do |store|
      assert_equal :deployed, store.deploy_surface(descriptor.wire, now:)
      assert_equal :deployed, store.deploy_surface(descriptor(revision: 2).wire, now:)
      assert_equal :duplicate, store.deploy_surface(descriptor(revision: 2).wire, now:)
      assert_equal descriptor(revision: 2).definition_digest,
                   store.surface(surface_id: 'telegram-ops').fetch('definition_digest')
    end
  end

  def test_admit_and_enqueue_is_one_transaction_and_dedups_replays
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      result = admit(store, envelope)

      assert_equal :enqueued, result
      assert_equal :duplicate, admit(store, envelope, now: now + 1)

      requests = checkpoints.request_history(thread_id: 'tg.ops.abc')

      assert_equal 1, requests.length, 'the replay must not enqueue twice'
      assert_equal :turn, requests.first.operation
      refute requests.first.payload.key?('conversation'),
             'a first contact has no transcript; the payload stays bare'
    end
  end

  # Invariant 1: an exact replay maps to the ONE existing request — one
  # inbound row, one enqueued turn, nothing new.
  def test_an_exact_duplicate_maps_to_the_one_existing_request
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      admit(store, envelope(update_id: 7))
      outcome = admit(store, envelope(update_id: 7))

      assert_equal :duplicate, outcome
      assert_equal 1, checkpoints.request_history(thread_id: 'tg.ops.abc').length
      assert_equal 1, request_row_count(store)
      assert_equal [%w[request accepted]], inbound_dispositions(store, 7)
    end
  end

  # Invariant 1 / hard-zero list: the SAME (surface, bot, update_id) under a
  # DIFFERENT payload digest is never silently deduplicated — and it never
  # grows storage either: every conflicting digest lands on the ONE anchor
  # row as a counter plus the last conflicting digest, enqueuing nothing.
  def test_three_conflicting_digests_share_one_anchor_row_with_counters
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      first = envelope(update_id: 9, raw_payload_hash: 'a' * 64)
      second = envelope(update_id: 9, raw_payload_hash: 'b' * 64)
      third = envelope(update_id: 9, raw_payload_hash: 'c' * 64)

      assert_equal :enqueued, admit(store, first)
      assert_equal :integrity_conflict, admit(store, second)
      assert_equal :conflict_recorded, store.disposition_only(
        second, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                disposition: 'quarantined', reason: 'integrity_conflict', now: now + 1
      )
      assert_equal :integrity_conflict, admit(store, third)

      rows = inbound_anchor_rows(store, 9)

      assert_equal 1, rows.length, 'conflicts are counters on the anchor row, never more rows'
      anchor = rows.first

      assert_equal('a' * 64, anchor.fetch('raw_payload_hash'))
      assert_equal 2, anchor.fetch('conflict_count')
      assert_equal('c' * 64, anchor.fetch('last_conflict_digest'))
      assert_equal(%w[quarantined integrity_conflict],
                   [anchor.fetch('disposition'), anchor.fetch('reason')])
      assert_equal 1, request_row_count(store), 'the original request row is untouched'
      assert_equal 1, checkpoints.request_history(thread_id: 'tg.ops.abc').length,
                   'no conflicting digest ever becomes a turn'

      assert_equal :integrity_conflict, admit(store, third, now: now + 2),
                   'a replayed conflict stays a conflict'
      assert_equal 2, inbound_anchor_rows(store, 9).first.fetch('conflict_count'),
                   'the same conflicting bytes count once'

      assert_equal :duplicate, admit(store, first, now: now + 3),
                   'the original digest still replays as a duplicate'
      assert_equal :duplicate, store.disposition_only(
        third, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
               disposition: 'quarantined', reason: 'integrity_conflict', now: now + 4
      ), 're-recording the identical quarantine dedups'
    end
  end

  # Declared limits are enforced at the admission boundary from the DEPLOYED
  # surface row (invariant 10): a breach refuses with its typed symbol and
  # inserts nothing into requests, inbox, or inbound.
  def test_the_open_request_limit_refuses_at_admission_without_enqueueing
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor(limits: { max_open_requests: 1 }).wire, now:)

      assert_equal :enqueued, admit(store, envelope(update_id: 11))
      assert_equal :open_request_limit, admit(store, envelope(update_id: 12))

      assert_equal 1, checkpoints.request_history(thread_id: 'tg.ops.abc').length
      assert_equal 1, request_row_count(store)
      assert_empty inbound_dispositions(store, 12), 'the refusal inserts no inbound row'
    end
  end

  def test_oversized_inbound_text_refuses_at_admission_without_enqueueing
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor(limits: { max_inbound_bytes: 32 }).wire, now:)

      assert_equal :inbound_too_large, admit(store, envelope(update_id: 13, text: 'x' * 33))

      assert_empty checkpoints.request_history(thread_id: 'tg.ops.abc')
      assert_empty inbound_dispositions(store, 13), 'the refusal inserts no inbound row'
    end
  end

  # Declared intake limits are inclusive bounds: text AT max_inbound_bytes
  # admits, and the request AT open-request capacity fills the last slot —
  # only the NEXT one refuses.
  def test_exact_boundary_limits_admit_at_the_line_and_refuse_the_next
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor(limits: { max_inbound_bytes: 32, max_open_requests: 2 }).wire, now:)

      assert_equal :enqueued, admit(store, envelope(update_id: 71, text: 'x' * 32)),
                   'text exactly at max_inbound_bytes is within the bound'
      assert_equal :enqueued, admit(store, envelope(update_id: 72)), 'the second slot fills'
      assert_equal :open_request_limit, admit(store, envelope(update_id: 73)),
                   'the request past max_open_requests refuses'
      assert_equal 2, checkpoints.request_history(thread_id: 'tg.ops.abc').length
    end
  end

  # A terminal projection releases its reservation (design §12): once the
  # request completes, its slot returns and the previously-refused admission
  # goes through.
  def test_a_completed_request_releases_its_slot_for_the_next_admission
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor(limits: { max_open_requests: 1 }).wire, now:)

      assert_equal :enqueued, admit(store, envelope(update_id: 81))
      request_id = checkpoints.request_history(thread_id: 'tg.ops.abc').first.request_id
      assert_equal :open_request_limit, admit(store, envelope(update_id: 82))

      assert_equal :released, store.complete_request(thread_id: 'tg.ops.abc', request_id: request_id)

      assert_equal :enqueued, admit(store, envelope(update_id: 82)),
                   'the freed slot lets the next admission through'
    end
  end

  # Invariant 4 fenced result recording: only the current claim's owner AND
  # fence may mark an outcome; a losing caller records nothing.
  def test_mark_delivery_is_fenced_to_the_current_claim_owner_and_fence
    with_engine do |store|
      store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 10, now:)
      delivery_id = delivery.fetch('delivery_id')
      store.claim_delivery(delivery_id:, owner: 'gateway:a', fence: 7,
                           claim_expires_at: now + 30, now:)

      assert_equal :not_claimable, store.mark_delivery(
        delivery_id:, owner: 'gateway:b', fence: 7, status: 'succeeded',
        receipt: { 'message_id' => 1 }, now: now + 1
      )
      assert_equal :not_claimable, store.mark_delivery(
        delivery_id:, owner: 'gateway:a', fence: 8, status: 'succeeded',
        receipt: { 'message_id' => 1 }, now: now + 2
      )
      row = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[claimed]).first

      assert_equal 'claimed', row.fetch('status'), 'a losing mark changes nothing'
      assert_nil row.fetch('receipt')

      assert_equal :marked, store.mark_delivery(
        delivery_id:, owner: 'gateway:a', fence: 7, status: 'succeeded',
        receipt: { 'message_id' => 42 }, now: now + 3
      )
      row = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded]).first

      assert_equal 'succeeded', row.fetch('status')
      assert_includes row.fetch('receipt'), '42'
    end
  end

  # The transcript a turn is planned with: admitted task texts interleaved
  # with the terminal replies the correspondent confirmably saw (invariant
  # 11 — the answer enters only once its delivery is `succeeded`). Control
  # deliveries ('Accepted…') and non-admitted messages never enter it.
  def test_conversation_history_interleaves_admitted_tasks_and_terminal_replies
    with_engine do |store, _adapter, _checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      store.admit_and_enqueue(
        envelope(update_id: 1, text: 'make it blue'), surface_id: 'telegram-ops',
                                                      bot_id: 7_463_512_990, thread: 'tg.ops.abc', profile_id: 'ops',
                                                      reservation: 1, now:
      )
      answer = delivery(text: 'done, it is blue')
      store.append_delivery(answer, surface_id: 'telegram-ops', capacity: 10, now: now + 1)
      claim_and_mark!(store, answer.fetch('delivery_id'), 'succeeded')
      store.append_delivery(
        delivery(text: 'Accepted. I will report committed progress.', kind: 'control',
                 journaled: false, content_digest: 'c' * 64),
        surface_id: 'telegram-ops', capacity: 10, now: now + 1
      )
      store.admit_and_enqueue(
        envelope(update_id: 2, text: 'and the font?'), surface_id: 'telegram-ops',
                                                       bot_id: 7_463_512_990, thread: 'tg.ops.abc', profile_id: 'ops',
                                                       reservation: 1, now: now + 2
      )

      history = store.conversation_history(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
      )

      assert_equal(
        [
          { 'role' => 'user', 'text' => 'make it blue' },
          { 'role' => 'assistant', 'text' => 'done, it is blue' },
          { 'role' => 'user', 'text' => 'and the font?' }
        ],
        history
      )
    end
  end

  # The history rides inside the payload's task entry, so the worker — which
  # never sees the comms store — plans the turn with the thread's context.
  def test_admit_and_enqueue_carries_the_history_in_the_turn_payload
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      history = [{ 'role' => 'user', 'text' => 'earlier' }]
      store.admit_and_enqueue(
        envelope, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                  thread: 'tg.ops.abc', profile_id: 'ops', reservation: 1,
                  now:, history:
      )

      payload = checkpoints.request_history(thread_id: 'tg.ops.abc').first.payload

      task = payload.fetch('task')
      assert_equal 'hello', task.fetch('text')
      context = task.fetch('context')
      assert_equal 'tg.ops.abc', context.fetch('thread_id')
      assert_equal checkpoints.request_history(thread_id: 'tg.ops.abc').first.request_id,
                   context.fetch('request_id')
      assert_equal history, context.fetch('fragments')
      assert_equal Tamoz::Core::TurnContext.digest(context.reject { |key, _| key == 'digest' }),
                   context.fetch('digest')
    end
  end

  def test_disposition_only_records_and_dedups
    with_engine do |store|
      assert_equal :recorded, store.disposition_only(
        envelope(update_id: 1), surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                                disposition: 'ignored', reason: 'unbound', now:
      )
      assert_equal :duplicate, store.disposition_only(
        envelope(update_id: 1), surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                                disposition: 'ignored', reason: 'unbound', now: now + 1
      )
    end
  end

  def test_poller_lease_is_one_fenced_poller_per_bot
    with_engine do |store|
      assert_equal :acquired, store.acquire_poller_lease(
        surface_id: 'telegram-ops', bot_id: 1, owner: 'gateway:a', fence: 1, ttl_s: 30, now:
      )
      assert_equal :not_acquirable, store.acquire_poller_lease(
        surface_id: 'telegram-ops', bot_id: 1, owner: 'gateway:b', fence: 2, ttl_s: 30, now: now + 1
      )
      assert_equal :acquired, store.acquire_poller_lease(
        surface_id: 'telegram-ops', bot_id: 1, owner: 'gateway:b', fence: 2, ttl_s: 30,
        now: now + 60
      ), 'an expired poller lease is recoverable'
    end
  end

  def test_next_offset_persists_only_forward
    with_engine do |store|
      assert_equal :persisted, store.persist_next_offset(
        surface_id: 'telegram-ops', bot_id: 1, next_offset: 100, now:
      )
      assert_equal :persisted, store.persist_next_offset(
        surface_id: 'telegram-ops', bot_id: 1, next_offset: 200, now: now + 1
      )
      assert_equal :behind, store.persist_next_offset(
        surface_id: 'telegram-ops', bot_id: 1, next_offset: 150, now: now + 2
      ), 'a stale offset must never regress the durable one'
    end
  end

  def test_outbox_append_is_bounded_and_deduped
    with_engine do |store|
      assert_equal :appended, store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 2, now:)
      assert_equal :duplicate, store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 2, now: now + 1)
      assert_equal :appended, store.append_delivery(
        delivery(conversation_id: 'telegram:chat:33333333'), surface_id: 'telegram-ops', capacity: 2, now:
      )
      assert_equal :capacity_refused, store.append_delivery(
        delivery(conversation_id: 'telegram:chat:44444444'), surface_id: 'telegram-ops', capacity: 2, now:
      )
    end
  end

  def test_outbox_claim_is_a_single_winner_compare_and_set
    with_engine do |store|
      store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 10, now:)
      delivery_id = delivery.fetch('delivery_id')

      assert_equal :claimed, store.claim_delivery(
        delivery_id:, owner: 'gateway:a', fence: 1, claim_expires_at: now + 30, now:
      )
      assert_equal :not_claimable, store.claim_delivery(
        delivery_id:, owner: 'gateway:b', fence: 2, claim_expires_at: now + 30, now: now + 1
      )
      assert_equal :missing, store.claim_delivery(
        delivery_id: 'f' * 64, owner: 'gateway:b', fence: 2, claim_expires_at: now + 30, now:
      )
    end
  end

  def test_bind_journal_effect_is_write_once
    with_engine do |store|
      store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 10, now:)
      delivery_id = delivery.fetch('delivery_id')

      assert_equal :bound, store.bind_journal_effect(
        delivery_id:, effect_key: "sha256:#{'e' * 64}", execution_id: "comms:#{delivery_id}", now:
      )
      assert_equal :bound, store.bind_journal_effect(
        delivery_id:, effect_key: "sha256:#{'e' * 64}", execution_id: "comms:#{delivery_id}", now:
      ), 'the same binding is idempotent'
      assert_equal :conflict, store.bind_journal_effect(
        delivery_id:, effect_key: "sha256:#{'d' * 64}", execution_id: "comms:#{delivery_id}", now:
      )
    end
  end

  def test_prompt_activation_requires_a_live_inactive_prompt
    with_engine do |store|
      insert_prompt!(store, reference: 'c' * 64)
      insert_prompt!(store, reference: 'd' * 64, status: 'active')
      insert_prompt!(store, reference: 'e' * 64, expires_at: now - 1)

      assert_equal :activated, store.activate_prompt(reference_digest: 'c' * 64, now: now + 1, receipt: '2001')
      assert_equal :already_active, store.activate_prompt(reference_digest: 'd' * 64, now: now + 1, receipt: '2002')
      assert_equal :expired, store.activate_prompt(reference_digest: 'e' * 64, now: now + 1, receipt: '2003')
      assert_equal :missing, store.activate_prompt(reference_digest: 'f' * 64, now: now + 1, receipt: '2004')
    end
  end

  def test_consume_prompt_inserts_its_decision_in_one_transaction
    with_engine do |store, _adapter, _checkpoints, path|
      insert_prompt!(store, reference: 'c' * 64, status: 'active')

      assert_equal :consumed, store.consume_prompt(
        reference_digest: 'c' * 64, decision_wire: decision_wire, now: now + 1
      )
      assert_equal :not_consumable, store.consume_prompt(
        reference_digest: 'c' * 64, decision_wire: decision_wire, now: now + 2
      ), 'a replayed reference is consumed exactly once'

      reopened = Tamoz::SQLite::Adapter.new(path:)
      begin
        decisions = reopened.bind_comms_decision_store.each_decision(thread_id: 'tg.ops.abc')

        assert_equal 1, decisions.length
        assert_equal 'pending', decisions.first.fetch('status'),
                     'the callback records a pending decision for the worker to consume'
        assert_equal 'deny', decisions.first.fetch('direction')
      ensure
        reopened&.close
      end
    end
  end

  def test_revoke_binding_deletes_inactive_prompts_atomically
    with_engine do |store|
      binding_wire = Comms::Binding.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        correspondent_id: 'telegram:user:11111111',
        conversation_id: 'telegram:chat:22222222',
        bound_at: now, bound_by: 'operator:ghassan'
      ).wire

      assert_equal :bound, store.bind_correspondent(binding_wire, now:)
      insert_prompt!(store, reference: 'c' * 64)
      insert_prompt!(store, reference: 'd' * 64, status: 'active')

      assert_equal :revoked, store.revoke_binding(
        correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops',
        reason: 'owner request', now: now + 10
      )
      assert_equal :revoked, store.revoke_binding(
        correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops',
        reason: 'owner request', now: now + 11
      ), 'revoking an already-revoked binding is idempotent'

      latest = store.binding(correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops')

      assert_equal 'revoked', latest.fetch('status')
      assert_nil store.prompt(reference_digest: 'c' * 64), 'inactive prompts are invalidated'
      refute_nil store.prompt(reference_digest: 'd' * 64), 'an active prompt survives revocation'
    end
  end

  def test_conversation_route_is_write_once_per_revision
    with_engine do |store|
      route = Comms::Conversation.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        conversation_id: 'telegram:chat:22222222', thread_id: 'tg.ops.abc',
        profile_id: 'ops', bound_at: now
      ).wire

      assert_equal :bound, store.bind_conversation(route, now:)
      assert_equal :duplicate, store.bind_conversation(route, now: now + 1)

      assert_equal 'tg.ops.abc', store.conversation(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
      ).fetch('thread_id')
    end
  end

  # Plan 02 work item 3: the status projection is reference-addressed and
  # queue-aware from durable rows alone — the active request's short
  # reference, its queue position, and the age of the oldest admitted
  # request — and none of those keys exist when nothing is admitted.
  def test_conversation_status_is_reference_addressed_and_queue_aware
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      bind_route!(store)

      idle = store.conversation_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222', now:
      )

      assert_equal 'idle', idle.fetch('state')
      refute idle.key?('request_ref')
      refute idle.key?('queue_position')
      refute idle.key?('queue_age_ms')

      assert_equal :enqueued, admit(store, envelope(update_id: 41), now:)
      assert_equal :enqueued, admit(store, envelope(update_id: 42), now: now + 1)

      active = request_ids(checkpoints, 'tg.ops.abc').last
      status = store.conversation_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222', now: now + 5
      )

      assert_equal 'accepted', status.fetch('state')
      assert_equal 2, status.fetch('open_requests')
      assert_equal active, status.fetch('request_id')
      assert_equal "r#{active[0, 10]}", status.fetch('request_ref')
      assert_equal 1, status.fetch('queue_position'), 'one admitted request is older than the active one'
      assert_equal 5_000, status.fetch('queue_age_ms')
    end
  end

  def test_a_unique_reference_resolves_to_its_full_status_and_unknown_fails_typed
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      bind_route!(store)
      assert_equal :enqueued, admit(store, envelope(update_id: 51))
      request_id = request_ids(checkpoints, 'tg.ops.abc').first

      found = store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: "r#{request_id[0, 10]}", now:
      )

      assert_kind_of Hash, found
      assert_equal request_id, found.fetch('request_id')
      assert_equal "r#{request_id[0, 10]}", found.fetch('request_ref')
      assert_equal 'tg.ops.abc', found.fetch('thread_id')
      assert_equal 0, found.fetch('queue_position')
      assert found.key?('terminal_reason')

      assert_equal :unknown_ref, store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: 'r0000000000', now:
      )
      assert_equal :unknown_ref, store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: 'half-a-ref', now:
      ), 'a malformed reference resolves to nothing'
    end
  end

  def test_a_reference_never_resolves_across_conversations
    with_engine do |store, _adapter, checkpoints|
      store.deploy_surface(descriptor.wire, now:)
      bind_route!(store)
      bind_route!(store, thread: 'tg.ops.other', conversation_id: 'telegram:chat:33333333')

      assert_equal :enqueued, admit(store, envelope(update_id: 61))
      foreign_ref = "r#{request_ids(checkpoints, 'tg.ops.abc').first[0, 10]}"

      assert_equal :unknown_ref, store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:33333333',
        ref: foreign_ref, now:
      ), 'the caller-bound scope never leaks another conversation\'s request'

      assert_kind_of Hash, store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: foreign_ref, now:
      )
    end
  end

  def test_an_ambiguous_reference_is_typed_not_guessed
    with_engine do |store|
      store.deploy_surface(descriptor.wire, now:)
      bind_route!(store)
      insert_request!(store, request_id: 'a' * 63 + '1',
                           conversation_id: 'telegram:chat:22222222', created_at_ms: 1_000)
      insert_request!(store, request_id: 'a' * 63 + '2',
                           conversation_id: 'telegram:chat:22222222', created_at_ms: 1_000)

      assert_equal :ambiguous_ref, store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: "r#{'a' * 10}", now:
      )
    end
  end

  # Invariant 11 (plan 02 work item 5): history inclusion requires confirmed
  # delivery — a journaled terminal answer enters only when its SAME row is
  # `succeeded`; pending and unknown stay out of every later model prompt.
  def test_history_includes_only_confirmed_successful_terminal_deliveries
    with_engine do |store|
      store.deploy_surface(descriptor.wire, now:)
      draft = delivery(text: 'draft answer', content_digest: 'b' * 63 + '1')
      lost = delivery(text: 'lost reply', content_digest: 'b' * 63 + '2')
      store.append_delivery(draft, surface_id: 'telegram-ops', capacity: 10, now:)
      store.append_delivery(lost, surface_id: 'telegram-ops', capacity: 10, now: now + 1)
      assistant_texts = lambda {
        store.conversation_history(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222')
             .select { |entry| entry.fetch('role') == 'assistant' }.map { |entry| entry.fetch('text') }
      }

      assert_empty(assistant_texts.call, 'pending terminal output never enters history')

      claim_and_mark!(store, draft.fetch('delivery_id'), 'succeeded')
      claim_and_mark!(store, lost.fetch('delivery_id'), 'unknown')

      assert_includes assistant_texts.call, 'draft answer', 'the same row flipped to succeeded IS included'
      refute_includes assistant_texts.call, 'lost reply', 'an unknown outcome stays out of history'
    end
  end

  def claim_and_mark!(store, delivery_id, status)
    assert_equal :claimed, store.claim_delivery(
      delivery_id:, owner: 'gateway:a', fence: 7, claim_expires_at: now + 30, now:
    )
    assert_equal :marked, store.mark_delivery(
      delivery_id:, owner: 'gateway:a', fence: 7, status:, now: now + 1
    )
  end

  # Plan 02 work item 4: `/new` bumps a durable per-conversation generation;
  # an absent conversation row raises before anything mutates.
  def test_generation_bumps_are_durable_and_absent_rows_raise
    Dir.mktmpdir('tamoz-comms-generation') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      first = Tamoz::SQLite::Adapter.new(path:)
      begin
        store = first.bind_comms_store
        bind_route!(store)

        assert_equal 0, store.conversation_generation(
          surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
        )
        assert_equal 1, store.bump_generation(
          surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
        )
        assert_equal 2, store.bump_generation(
          surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
        )

        error = assert_raises(KeyError) do
          store.bump_generation(surface_id: 'telegram-ops', conversation_id: 'telegram:chat:99999999')
        end

        assert_match(/not bound/, error.message)
      ensure
        first&.close
      end

      reopened = Tamoz::SQLite::Adapter.new(path:)
      begin
        store = reopened.bind_comms_store

        assert_equal 2, store.conversation_generation(
          surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222'
        ), 'the bump is durable across a reopen'
      ensure
        reopened&.close
      end
    end
  end

  # Plan 02 work item 5: reply_to survives append -> outbox row -> the
  # drainer's Delivery rebuild, so it reaches the transport untouched.
  def test_reply_to_round_trips_from_append_to_transport_wire
    with_engine do |store|
      store.append_delivery(delivery(reply_to: 4242), surface_id: 'telegram-ops', capacity: 10, now:)
      store.append_delivery(
        delivery(content_digest: 'c' * 64), surface_id: 'telegram-ops', capacity: 10, now: now + 1
      )

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
      rebuilt = Comms::Delivery.from_wire(rows.first.merge('journaled' => rows.first.fetch('journaled') == 1))

      assert_equal 4242, rows.first.fetch('reply_to')
      assert_equal 4242, rebuilt.reply_to, 'the drainer rebuild carries reply_to to the transport'
      assert_nil rows.last.fetch('reply_to'), 'rows without a target round-trip nil'
    end
  end

  def test_a_restart_sees_the_same_rows
    Dir.mktmpdir('tamoz-comms-restart') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      first = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'comms-seed', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'comms-seed.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: first).checkpointer
        store = first.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now:)
        store.append_delivery(delivery, surface_id: 'telegram-ops', capacity: 10, now:)
        store.persist_next_offset(surface_id: 'telegram-ops', bot_id: 1, next_offset: 100, now:)
      ensure
        first&.close
      end

      reopened = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'comms-reopen', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'comms-reopen.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: reopened).checkpointer
        store = reopened.bind_comms_store(checkpoints)

        assert_equal descriptor.definition_digest,
                     store.surface(surface_id: 'telegram-ops').fetch('definition_digest')
        assert_equal 1, store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).length
        assert_equal :behind, store.persist_next_offset(
          surface_id: 'telegram-ops', bot_id: 1, next_offset: 50, now: now + 5
        ), 'the durable offset survives a restart'
      ensure
        reopened&.close
      end
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:enable Metrics/BlockLength, Metrics/ClassLength
