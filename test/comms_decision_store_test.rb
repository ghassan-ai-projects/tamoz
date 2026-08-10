# frozen_string_literal: true

require_relative 'test_helper'

# Slice A (COMMS_TELEGRAM_PLAN §3) — the durable decision store over the
# versioned Store namespace. Every transition is a compare-and-set: exactly
# one concurrent claimer wins, an expired claim lease releases the record for
# crash recovery, and consumption is idempotent. The contract-version pair
# (dependency rule 9) is verified by the integration layer that loads both.
#
# Each case walks the store through one state machine (insert, claim, consume)
# end to end; the assertions belong to the same scenario.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
class CommsDecisionStoreTest < Minitest::Test
  Comms = Tamoz::Comms
  Store = Tamoz::SQLite::CommsDecisionStore

  def with_store
    Dir.mktmpdir('tamoz-comms-store') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        yield Store.new(adapter.store), adapter
      ensure
        adapter&.close
      end
    end
  end

  def interrupts = [{ task_id: 's1', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }]

  def decided_at = Time.utc(2026, 8, 10, 12, 0, 0)

  def record(thread_id: 't1', occurrence_id: 'req-1', direction: :deny, decided: decided_at, ttl_s: 900)
    Comms::DecisionRecord.build(
      thread_id:, occurrence_id:, interrupts: interrupts,
      direction:, actor_kind: 'os_user', actor_id: '501', source: 'cli',
      decided_at: decided, ttl_s:
    )
  end

  def test_contract_version_pairs_with_the_contract_gem
    assert_equal Comms::DecisionStore::CONTRACT_VERSION, Store::CONTRACT_VERSION
  end

  def test_insert_is_create_only_and_duplicate_is_idempotent
    with_store do |store|
      value = record

      assert_equal :created, store.insert_decision(value.wire)
      assert_equal :duplicate, store.insert_decision(value.wire)
      assert_equal 1, store.each_decision(thread_id: 't1').length
    end
  end

  def test_pending_decision_for_matches_digest_thread_and_occurrence
    with_store do |store|
      value = record
      store.insert_decision(value.wire)

      found = store.pending_decision_for(
        thread_id: 't1', occurrence_id: 'req-1',
        interrupt_digest: value.interrupt_digest, now: decided_at + 1
      )

      assert_equal value.decision_id, found.fetch('decision_id')

      assert_nil store.pending_decision_for(
        thread_id: 'other', occurrence_id: 'req-1',
        interrupt_digest: value.interrupt_digest, now: decided_at + 1
      )
      assert_nil store.pending_decision_for(
        thread_id: 't1', occurrence_id: 'req-2',
        interrupt_digest: value.interrupt_digest, now: decided_at + 1
      )
      assert_nil store.pending_decision_for(
        thread_id: 't1', occurrence_id: 'req-1',
        interrupt_digest: '0' * 64, now: decided_at + 1
      )
    end
  end

  def test_an_expired_decision_is_never_returned
    with_store do |store|
      store.insert_decision(record(ttl_s: 1).wire)

      assert_nil store.pending_decision_for(
        thread_id: 't1', occurrence_id: 'req-1',
        interrupt_digest: record.interrupt_digest, now: decided_at + 60
      )
    end
  end

  def test_a_later_decision_on_the_same_question_wins
    with_store do |store|
      first = record(direction: :approve, decided: decided_at)
      second = record(direction: :deny, decided: decided_at + 5)
      store.insert_decision(first.wire)
      store.insert_decision(second.wire)

      found = store.pending_decision_for(
        thread_id: 't1', occurrence_id: 'req-1',
        interrupt_digest: first.interrupt_digest, now: decided_at + 10
      )

      assert_equal second.decision_id, found.fetch('decision_id'),
                   "the operator's latest word on the same question must win"
    end
  end

  def test_claim_is_a_single_winner_compare_and_set
    with_store do |store|
      value = record
      store.insert_decision(value.wire)

      assert_equal :claimed, store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:a', fence: 1,
        claim_expires_at: decided_at + 30, now: decided_at
      )
      assert_equal :not_claimable, store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:b', fence: 2,
        claim_expires_at: decided_at + 30, now: decided_at + 1
      )
      assert_equal :missing, store.claim_decision(
        decision_id: 'f' * 64, owner: 'worker:b', fence: 2,
        claim_expires_at: decided_at + 30, now: decided_at + 1
      )
    end
  end

  def test_an_expired_claim_lease_is_claimable_again
    with_store do |store|
      value = record
      store.insert_decision(value.wire)
      store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:a', fence: 1,
        claim_expires_at: decided_at + 30, now: decided_at
      )

      # The claimer died before submitting; after the lease expires, the record
      # is recoverable — the crash-before-submission path (design §9).
      assert_equal :claimed, store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:b', fence: 2,
        claim_expires_at: decided_at + 90, now: decided_at + 60
      )
      assert_equal 'worker:b', store.each_decision(thread_id: 't1')
                                    .first.fetch('claim_owner')
    end
  end

  def test_consume_requires_a_claim_and_is_idempotent
    with_store do |store|
      value = record
      store.insert_decision(value.wire)

      assert_equal :not_consumable, store.consume_decision(
        decision_id: value.decision_id, now: decided_at + 1
      )
      assert_equal :missing, store.consume_decision(
        decision_id: 'f' * 64, now: decided_at + 1
      )

      store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:a', fence: 1,
        claim_expires_at: decided_at + 30, now: decided_at
      )

      assert_equal :consumed, store.consume_decision(
        decision_id: value.decision_id, now: decided_at + 1
      )
      assert_equal :consumed, store.consume_decision(
        decision_id: value.decision_id, now: decided_at + 2
      )

      rows = store.each_decision(thread_id: 't1')

      assert_equal 1, rows.length
      assert_equal 'consumed', rows.first.fetch('status')
      refute_nil rows.first.fetch('consumed_at')
    end
  end

  def test_a_consumed_decision_cannot_be_claimed
    with_store do |store|
      value = record
      store.insert_decision(value.wire)
      store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:a', fence: 1,
        claim_expires_at: decided_at + 30, now: decided_at
      )
      store.consume_decision(decision_id: value.decision_id, now: decided_at + 1)

      assert_equal :not_claimable, store.claim_decision(
        decision_id: value.decision_id, owner: 'worker:b', fence: 2,
        claim_expires_at: decided_at + 60, now: decided_at + 60
      )
    end
  end

  def test_each_decision_returns_thread_rows_newest_first
    with_store do |store|
      store.insert_decision(record(thread_id: 't1', occurrence_id: 'r1',
                                   decided: decided_at).wire)
      store.insert_decision(record(thread_id: 't1', occurrence_id: 'r2',
                                   decided: decided_at + 60).wire)
      store.insert_decision(record(thread_id: 't2', occurrence_id: 'r3',
                                   decided: decided_at + 120).wire)

      rows = store.each_decision(thread_id: 't1')

      assert_equal(%w[r2 r1], rows.map { |row| row.fetch('occurrence_id') })
      assert_equal 1, store.each_decision(thread_id: 't2').length
    end
  end

  def test_a_restart_sees_the_same_records
    Dir.mktmpdir('tamoz-comms-store') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      value = record
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        adapter.bind_comms_decision_store.insert_decision(value.wire)
      ensure
        adapter&.close
      end

      reopened = Tamoz::SQLite::Adapter.new(path:)
      begin
        store = Store.new(reopened.store)
        found = store.pending_decision_for(
          thread_id: 't1', occurrence_id: 'req-1',
          interrupt_digest: value.interrupt_digest, now: decided_at + 1
        )

        assert_equal value.decision_id, found.fetch('decision_id')
      ensure
        reopened&.close
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
