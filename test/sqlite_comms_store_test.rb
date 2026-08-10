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
# to the same scenario. rubocop:disable Minitest/MultipleAssertions
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

  def descriptor(**overrides)
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
                global_messages_per_s: 25.0 },
      **overrides
    )
  end

  def envelope(update_id: 12_345, text: 'hello', **overrides)
    Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id:,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      text:, observed_time: now, **overrides
    ).wire
  end

  def delivery(**overrides)
    Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'ok',
      part_index: 0, part_count: 1, journaled: true, render_version: 1,
      content_digest: 'b' * 64, **overrides
    ).wire
  end

  def prompt_wire(reference:, status: 'inactive', expires_at: now + 900, thread: 'tg.ops.abc')
    {
      'reference_digest' => reference, 'surface_id' => 'telegram-ops',
      'surface_revision' => 1, 'thread_id' => thread, 'occurrence_id' => 'req-1',
      'interrupt_digest' => 'c' * 64, 'correspondent_id' => 'telegram:user:11111111',
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
          occurrence_id, interrupt_digest, correspondent_id, conversation_id,
          prompt_receipt, status, created_at_ms, activated_at_ms, consumed_at_ms,
          expires_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
  end

  def prompt_binds(wire)
    [
      wire.fetch('reference_digest'), wire['surface_id'], wire['surface_revision'],
      wire.fetch('thread_id'), wire.fetch('occurrence_id'), wire.fetch('interrupt_digest'),
      wire.fetch('correspondent_id'), wire.fetch('conversation_id'), wire['prompt_receipt'],
      wire.fetch('status'), ms(wire.fetch('created_at')), ms(wire['activated_at']),
      ms(wire['consumed_at']), ms(wire.fetch('expires_at'))
    ]
  end

  def ms(value)
    value && ((Time.parse(value).utc.to_r * 1000).to_i)
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
      result = store.admit_and_enqueue(
        envelope, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
        thread: 'tg.ops.abc', profile_id: 'ops', reservation: 1, now:
      )
      assert_equal :enqueued, result
      assert_equal :duplicate, store.admit_and_enqueue(
        envelope, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
        thread: 'tg.ops.abc', profile_id: 'ops', reservation: 1, now: now + 1
      )

      requests = checkpoints.request_history(thread_id: 'tg.ops.abc')
      assert_equal 1, requests.length, 'the replay must not enqueue twice'
      assert_equal :turn, requests.first.operation
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

      assert_equal :activated, store.activate_prompt(reference_digest: 'c' * 64, now: now + 1)
      assert_equal :already_active, store.activate_prompt(reference_digest: 'd' * 64, now: now + 1)
      assert_equal :expired, store.activate_prompt(reference_digest: 'e' * 64, now: now + 1)
      assert_equal :missing, store.activate_prompt(reference_digest: 'f' * 64, now: now + 1)
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
# rubocop:enable Minitest/MultipleAssertions
