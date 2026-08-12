# frozen_string_literal: true

require_relative 'test_helper'

# Slice A (COMMS_TELEGRAM_PLAN §3) — the immutable DecisionRecord value and
# its digests. The security property under test: a decision binds the exact
# interrupt set it answers, deterministically and order-insensitively, so a
# decision for one question can never answer a later one in the same
# occurrence (invariant 58).
class CommsDecisionRecordTest < Minitest::Test
  Comms = Tamoz::Comms

  def interrupts
    [
      { task_id: 'edit1', call_index: 0, descriptor: { 'kind' => 'approve_tool',
                                                       'tool' => 'apply_patch',
                                                       'path' => 'note.txt' } }
    ]
  end

  def record(**overrides)
    Comms::DecisionRecord.build(
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1', interrupts: interrupts,
      direction: :deny, actor_kind: 'os_user', actor_id: '501', source: 'cli',
      decided_at: Time.utc(2026, 8, 10, 12, 0, 0),
      **overrides
    )
  end

  # One record, every derived property at once: the digest, the status, the
  # direction and the resume id are ONE construction's output.
  # rubocop:disable Minitest/MultipleAssertions
  def test_build_derives_stable_digests_and_defaults_to_pending
    value = record

    assert_match(/\A[0-9a-f]{64}\z/, value.decision_id)
    assert_match(/\A[0-9a-f]{64}\z/, value.interrupt_digest)
    assert_predicate value, :pending?
    refute_predicate value, :consumed?
    assert_predicate value, :denied?
    refute_predicate value, :granted?
    assert_equal "decision-#{value.decision_id}", value.resume_request_id
  end
  # rubocop:enable Minitest/MultipleAssertions

  # The id is derived, so equal inputs give equal ids — but decided_at is part
  # of the id: a LATER re-decision of the same question is a new decision
  # (single-use consumption), never a duplicate of a consumed one.
  def test_decision_id_is_derived_and_distinct_per_decision
    assert_equal record.decision_id, record.decision_id
    later = record(decided_at: Time.utc(2026, 8, 10, 12, 30, 0))

    refute_equal record.decision_id, later.decision_id
    assert_equal record.interrupt_digest, later.interrupt_digest
  end

  def test_interrupt_digest_is_order_insensitive_and_descriptor_sensitive
    a = { task_id: 'edit1', call_index: 0, descriptor: { 'kind' => 'approve_tool', 'tool' => 'apply_patch' } }
    b = { task_id: 'edit2', call_index: 0, descriptor: { 'kind' => 'approve_tool', 'tool' => 'create_file' } }

    assert_equal Comms::InterruptDigest.of([a, b]), Comms::InterruptDigest.of([b, a])

    changed = { task_id: 'edit2', call_index: 0, descriptor: { 'kind' => 'approve_tool', 'tool' => 'apply_patch' } }

    refute_equal Comms::InterruptDigest.of([a]), Comms::InterruptDigest.of([changed]),
                 'a different tool in the same position must change the digest'
  end

  def test_interrupt_digest_ignores_descriptor_key_order
    left = Comms::InterruptDigest.of([{ task_id: 's', call_index: 0,
                                        descriptor: { 'kind' => 'approve_tool', 'tool' => 'x', 'extra' => 1 } }])
    right = Comms::InterruptDigest.of([{ task_id: 's', call_index: 0,
                                         descriptor: { 'extra' => 1, 'tool' => 'x', 'kind' => 'approve_tool' } }])

    assert_equal left, right
  end

  def test_direction_changes_the_decision_but_not_the_question_digest
    approve = record(direction: :approve)
    deny = record(direction: :deny)

    refute_equal approve.decision_id, deny.decision_id
    assert_equal approve.interrupt_digest, deny.interrupt_digest
  end

  def test_expiry_is_checked_against_an_explicit_clock
    value = record

    assert value.expired?(Time.utc(2026, 8, 10, 12, 15, 1)),
           'the 900s TTL must have elapsed'
    refute value.expired?(Time.utc(2026, 8, 10, 12, 0, 1))
  end

  def test_wire_round_trip_preserves_every_field
    value = record
    copy = Comms::DecisionRecord.from_wire(value.wire)

    assert_equal value, copy
    assert_equal value.wire, copy.wire
    assert_equal 'pending', copy.wire.fetch('status')
  end

  # The claim/consumption fields survive a wire round trip as a set; each one
  # is asserted against the same record.
  # rubocop:disable Minitest/MultipleAssertions
  def test_wire_round_trip_preserves_claim_and_consumption_state
    value = Comms::DecisionRecord.from_wire(
      record.wire.merge(
        'status' => 'consumed',
        'claim_owner' => 'worker:abc',
        'claim_fence' => 42,
        'claim_expires_at' => '2026-08-10T12:01:00.000000Z',
        'consumed_at' => '2026-08-10T12:01:05.000000Z'
      )
    )

    assert_predicate value, :consumed?
    assert_equal 'worker:abc', value.claim_owner
    assert_equal 42, value.claim_fence
    assert_equal '2026-08-10T12:01:05.000000Z', value.consumed_at.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_validation_rejects_unknown_directions_actors_and_sources
    assert_raises(Comms::ValidationError) { record(direction: :grant) }
    assert_raises(Comms::ValidationError) { record(actor_kind: 'robot') }
    assert_raises(Comms::ValidationError) { record(source: 'web') }
  end

  def test_validation_rejects_a_claimed_record_without_claim_fields
    error = assert_raises(Comms::ValidationError) do
      Comms::DecisionRecord.from_wire(record.wire.merge('status' => 'claimed'))
    end
    assert_match(/claim_owner/, error.message)
  end

  def test_validation_rejects_a_consumed_record_without_a_consumption_time
    error = assert_raises(Comms::ValidationError) do
      Comms::DecisionRecord.from_wire(record.wire.merge('status' => 'consumed'))
    end
    assert_match(/consumed_at/, error.message)
  end

  def test_validation_rejects_expiry_before_decision
    error = assert_raises(Comms::ValidationError) do
      record(decided_at: Time.utc(2026, 8, 10, 12, 0, 0), ttl_s: -1)
    end
    assert_match(/expires_at must follow decided_at/, error.message)
  end

  # MIG-10 (ADR-049, contract §7.1): the operator audit trail — evidence level
  # and reason — survives the wire round trip.
  def test_operator_evidence_and_reason_round_trip_through_the_store
    value = record(evidence: 'filesystem_operator', reason: 'operator_command')

    assert_equal 'filesystem_operator', value.evidence
    assert_equal 'operator_command', value.reason
    assert_equal value.wire, Comms::DecisionRecord.from_wire(value.wire).wire
  end

  # MIG-10: the same audit trail persists in the SQLite decision store, so
  # `tamoz approve` writes evidence that the worker and audit can read back.
  def test_operator_evidence_persists_in_the_sqlite_decision_store
    value = record(evidence: 'filesystem_operator', reason: 'operator_command')

    Dir.mktmpdir('tamoz-decision-audit') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        store = adapter.bind_comms_decision_store

        assert_equal :created, store.insert_decision(value.wire)
        stored = store.pending_decision_for(
          thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
          interrupt_digest: value.interrupt_digest, now: Time.utc(2026, 8, 10, 12, 0, 1)
        )

        assert_equal 'filesystem_operator', stored.fetch('evidence')
        assert_equal 'operator_command', stored.fetch('reason')
      ensure
        adapter&.close
      end
    end
  end

  def test_validation_rejects_a_non_lattice_evidence_level
    error = assert_raises(Comms::ValidationError) do
      record(evidence: 'root')
    end
    assert_match(/evidence must be one of/, error.message)
  end
end
