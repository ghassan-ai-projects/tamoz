# frozen_string_literal: true

# Slice A (COMMS_TELEGRAM_PLAN §3) — the worker's decision consumption, from
# the direction that matters: a decision answers EXACTLY ONE interrupt set.
# Two approval rounds in one occurrence cannot reuse a decision (invariant
# 58), a wrong digest or an expired record is refused (fail closed), and the
# operator's latest word on the same question wins.

require_relative 'test_helper'
require_relative 'support/autonomy_case'

# Every case here is one full worker turn — queue, pause, decide, resume,
# settle — and each scenario is atomic: splitting it into one-assertion tests
# would re-run the turn per assertion. The metrics measure the scenario, not
# a method an author chose to overload.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Minitest/MultipleAssertions
class AgentDecisionFlowTest < Minitest::Test
  include AutonomyCase

  # Two sequential approval rounds in ONE occurrence. The first round's
  # decision must never answer the second: the second pause has a different
  # interrupt digest, so it stays parked until its own decision arrives.
  def test_a_decision_for_one_round_never_answers_a_later_round_in_the_same_occurrence
    with_runtime(unattended: { 'reconcilable' => [] }) do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      rt.cli(['queue', 'add', '--task', 'Fix twice', '--profile', 'trusted'], factory: two_edits_factory)
      rt.cli(%w[worker --once --json], factory: two_edits_factory)

      first = rt.pending_approvals

      assert_equal 1, first.length
      rt.cli(%W[approve #{first.first.fetch('request_id')} --json])
      rt.cli(%w[worker --once --json], factory: two_edits_factory)

      # Round two must be asking again — the round-one approval was consumed
      # for round one and cannot answer a different question. The occurrence
      # id is unchanged (same occurrence); the interrupt set is what changed.
      second = rt.pending_approvals

      assert_equal 1, second.length, 'round two must pause with its own question'
      assert_equal first.first.fetch('request_id'), second.first.fetch('request_id'),
                   'both rounds live in the same occurrence'
      refute_equal first.first.fetch('interrupts'), second.first.fetch('interrupts'),
                   'round two must pause on a different interrupt set'
      assert_equal "fixed\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'round one ran after its approval'

      rt.cli(%W[approve #{second.first.fetch('request_id')} --json])
      rt.cli(%w[worker --once --json], factory: two_edits_factory)

      assert_equal "final\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'round two must not complete until its own approval arrives'
      assert_empty rt.pending_approvals
      assert_equal 0, rt.counter('headless_auto_approvals')
    end
  end

  # A decision recorded for a DIFFERENT interrupt set (same occurrence) is
  # refused: the digest is part of the record's identity, so a stale decision
  # can never be silently consumed by a changed question.
  def test_a_wrong_digest_decision_is_refused_and_the_turn_stays_parked
    with_runtime(unattended: { 'reconcilable' => [] }) do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      rt.cli(['queue', 'add', '--task', 'Fix note.txt', '--profile', 'trusted'], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      pending = rt.pending_approvals.first
      write_decision(rt,
                     thread_id: pending.fetch('thread_id'),
                     occurrence_id: pending.fetch('request_id'),
                     interrupts: [{ task_id: 'other', call_index: 0,
                                    descriptor: { 'kind' => 'approve_tool', 'tool' => 'create_file' } }],
                     direction: :approve)

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'a decision for the wrong question must not resume the turn'
      assert_equal 1, rt.pending_approvals.length
    end
  end

  # An expired decision is refused: the record is only valid for its declared
  # lifetime (15 minutes default), and after that the turn stays parked until
  # the operator records a fresh decision.
  def test_an_expired_decision_is_refused_and_the_turn_stays_parked
    with_runtime(unattended: { 'reconcilable' => [] }) do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      rt.cli(['queue', 'add', '--task', 'Fix note.txt', '--profile', 'trusted'], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      pending = rt.pending_approvals.first
      write_decision(rt,
                     thread_id: pending.fetch('thread_id'),
                     occurrence_id: pending.fetch('request_id'),
                     interrupts: interrupts_of_pending(pending),
                     direction: :approve,
                     decided_at: Time.now.utc - 3600, ttl_s: 1)

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, 'note.txt'))
      assert_equal 1, rt.pending_approvals.length
    end
  end

  # The operator's latest word on the SAME question wins: approve then deny
  # before the worker sees either leaves the turn parked with the denial.
  def test_a_later_decision_on_the_same_question_supersedes_an_earlier_one
    with_runtime(unattended: { 'reconcilable' => [] }) do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      rt.cli(['queue', 'add', '--task', 'Fix note.txt', '--profile', 'trusted'], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      request_id = rt.pending_approvals.first.fetch('request_id')

      assert_equal 0, rt.cli(%W[approve #{request_id} --json]), rt.err
      assert_equal 0, rt.cli(%W[approve #{request_id} --deny --json]), rt.err
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "hello\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'the later denial must win over the earlier approval'
      assert_equal(1, rt.events.count { |event| event['event'] == 'request.denied' })
      assert_equal(0, rt.events.count { |event| event['event'] == 'request.approved' })
    end
  end

  # The claim/resume/consume sequence is crash-recoverable: a decision left
  # CLAIMED with an expired lease (a worker that died before resuming) is
  # reclaimed on the next pass, and the derived resume request id means the
  # re-submission cannot duplicate the resume (invariant 23).
  def test_an_expired_claim_is_recovered_without_duplicating_the_resume
    with_runtime(unattended: { 'reconcilable' => [] }) do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      rt.cli(['queue', 'add', '--task', 'Fix note.txt', '--profile', 'trusted'], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      pending = rt.pending_approvals.first
      thread_id = pending.fetch('thread_id')
      occurrence_id = pending.fetch('request_id')
      # The CLI records a decision with the exact interrupt digest the worker
      # computes; then a dead claimer claims it and never submits the resume.
      rt.cli(%W[approve #{occurrence_id} --json])
      with_decision_store(rt) do |store|
        rows = store.each_decision(thread_id:)

        assert_equal 1, rows.length
        decision_id = rows.first.fetch('decision_id')
        store.claim_decision(
          decision_id:, owner: 'worker:dead', fence: 1,
          claim_expires_at: Time.now.utc - 120, now: Time.now.utc - 120
        )
      end

      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "fixed\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'the expired claim must be recovered and the turn resumed'
      assert_equal(1, rt.events.count { |event| event['event'] == 'request.approved' })
      with_decision_store(rt) do |store|
        rows = store.each_decision(thread_id:)

        assert_equal 1, rows.length
        assert_equal 'consumed', rows.first.fetch('status')
      end
    end
  end

  private

  # A plan whose two sequential edits each require a separate approval round.
  def two_edits_factory
    lambda do |_options|
      ScriptedModel.new(
        plan: [
          plan_step('read_file', { 'path' => 'note.txt' }),
          {
            'goal' => 'fix note.txt twice',
            'done_when' => ['note.txt reads final'],
            'steps' => [
              { 'id' => 'edit1', 'purpose' => 'first edit', 'tool' => 'apply_patch',
                'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                'verification' => 'the receipt reports the new digest' },
              { 'id' => 'edit2', 'purpose' => 'second edit', 'tool' => 'apply_patch',
                'arguments' => { 'path' => 'note.txt', 'before' => 'fixed', 'after' => 'final' },
                'verification' => 'the receipt reports the new digest' }
            ]
          }
        ],
        review: [accepted_review],
        verify: [{ 'answer' => 'done', 'satisfied' => true, 'evidence' => ['note.txt'] }]
      )
    end
  end

  def interrupts_of_pending(pending)
    pending.fetch('interrupts').map do |interrupt|
      {
        task_id: interrupt.fetch('task_id'),
        call_index: interrupt.fetch('call_index'),
        descriptor: { 'kind' => interrupt['kind'], 'tool' => interrupt['tool'] }.compact
      }
    end
  end

  # Records a decision directly through the store (as the CLI would, but with
  # caller-controlled digest/expiry), bypassing the CLI's own derivation.
  def write_decision(runtime, thread_id:, occurrence_id:, interrupts:, direction:, **overrides)
    record = Tamoz::Comms::DecisionRecord.build(
      thread_id:, occurrence_id:, interrupts:, direction:,
      actor_kind: 'os_user', actor_id: 'test', source: 'cli', **overrides
    )
    with_decision_store(runtime) do |store|
      store.insert_decision(record.wire)
    end
    record
  end

  def with_decision_store(runtime)
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(runtime.dir, 'runtime.sqlite3'))
    begin
      yield adapter.bind_comms_decision_store
    ensure
      adapter&.close
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Minitest/MultipleAssertions
