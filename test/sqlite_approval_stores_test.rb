# frozen_string_literal: true

require_relative 'test_helper'

# Approval redesign phase 5 — the durable homes behind the Tamoz::Approval
# ports over a real SQLite database: rev-scoped grant lookup (stale rev never
# matches), idempotent decision-log append, resolution replay, the single-row
# active-policy record, receipt expiry, and migration 16→17 with its checksum.
class SqliteApprovalStoresTest < Minitest::Test
  Approval = Tamoz::Approval

  def with_adapter
    Dir.mktmpdir('tamoz-approval') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        yield adapter
      ensure
        adapter&.close
      end
    end
  end

  def grant(scope: :session, session_id: 's1', policy_rev: 'rev-a', expires_at_ms: nil)
    Approval::Grant.new(
      key: { verb: 'execute', tool: 'run_check' },
      scope: scope,
      session_id: session_id,
      policy_rev: policy_rev,
      created_at_ms: 1_000,
      expires_at_ms: expires_at_ms
    )
  end

  def test_migration_applies_on_fresh_database_and_checksum_verifies
    assert_equal 19, Tamoz::SQLite::Migrator::CURRENT_VERSION
    assert_equal (1..19).to_a, Tamoz::SQLite::Migrator.migration_ordinals

    with_adapter do |adapter|
      tables = adapter.__send__(:read, operation: 'test.tables') do |txn|
        txn.rows('test.tables', "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'tamoz_approval%'")
      end.map(&:first).sort

      assert_includes tables, 'tamoz_approval_grants'
      assert_includes tables, 'tamoz_approval_decisions'
      assert_includes tables, 'tamoz_approval_active_policy'
    end
  end

  def test_grant_lookup_matches_rev_scope_and_session_exactly
    with_adapter do |adapter|
      store = adapter.bind_approval_grant_store
      store.insert(grant)

      hit = store.lookup(key: grant.key, scope: :session, session_id: 's1', policy_rev: 'rev-a')
      assert_equal grant.key, hit.key
      refute_nil hit

      assert_nil store.lookup(key: grant.key, scope: :session, session_id: 's1', policy_rev: 'rev-b'),
                 'a stale-rev grant must never match at read time'
      assert_nil store.lookup(key: grant.key, scope: :session, session_id: 's2', policy_rev: 'rev-a')
      assert_nil store.lookup(key: { other: '1' }, scope: :session, session_id: 's1', policy_rev: 'rev-a')

      store.delete_by_session('s1')
      assert_nil store.lookup(key: grant.key, scope: :session, session_id: 's1', policy_rev: 'rev-a')
    end
  end

  def test_expired_grant_row_stays_a_pure_tuple_match
    with_adapter do |adapter|
      store = adapter.bind_approval_grant_store
      store.insert(grant(expires_at_ms: 1))

      # Expiry filtering is the Engine's job; the store returns the row and
      # the Engine discards it against its own clock.
      hit = store.lookup(key: grant.key, scope: :session, session_id: 's1', policy_rev: 'rev-a')
      refute_nil hit
      assert_equal 1, hit.expires_at_ms
    end
  end

  def test_key_encoding_is_order_insensitive
    with_adapter do |adapter|
      store = adapter.bind_approval_grant_store
      store.insert(grant)

      shuffled = { tool: 'run_check', verb: 'execute' }
      refute_nil store.lookup(key: shuffled, scope: :session, session_id: 's1', policy_rev: 'rev-a'),
                 'lookup must canonicalize the key the same way insert does'
    end
  end

  def test_decision_log_append_is_idempotent_on_decision_id
    with_adapter do |adapter|
      log = adapter.bind_approval_decision_log(clock: -> { Time.at(1_000) })
      record = decision_record

      log.append(record)
      log.append(record)

      count = adapter.__send__(:read, operation: 'test.count') do |txn|
        txn.scalar('test.count', 'SELECT COUNT(*) FROM tamoz_approval_decisions')
      end
      assert_equal 1, count
    end
  end

  def test_decision_log_append_with_different_content_raises
    with_adapter do |adapter|
      log = adapter.bind_approval_decision_log(clock: -> { Time.at(1_000) })
      log.append(decision_record)
      conflicting = decision_record(verdict: :allow)

      error = assert_raises(Approval::ConflictingResolutionError) do
        log.append(conflicting)
      end
      assert_match(/already logged/, error.message)
    end
  end

  def test_decision_log_round_trips_the_stored_decision
    with_adapter do |adapter|
      log = adapter.bind_approval_decision_log(clock: -> { Time.at(1_000) })
      record = decision_record
      log.append(record)

      loaded = log.lookup(record.fetch(:decision_id))
      decision = loaded.fetch(:decision)

      assert_equal record.fetch(:decision).id, decision.id
      assert_equal :ask, decision.verdict
      assert_equal :local_execute, decision.tier
      assert_equal 'filesystem_operator', decision.required_evidence.to_s
      assert_equal [:once, :session], decision.grant_offer.scopes
      assert_equal({ verb: 'execute', tool: 'run_check' }, decision.grant_offer.key)
    end
  end

  def test_resolution_records_replays_and_conflicts
    with_adapter do |adapter|
      log = adapter.bind_approval_decision_log(clock: -> { Time.at(1_000) })
      record = decision_record
      log.append(record)
      decision_id = record.fetch(:decision_id)
      minted = grant(policy_rev: record.fetch(:policy_rev))

      first = log.record_resolution(
        decision_id: decision_id,
        answer: :approve,
        scope: :session,
        actor_evidence: :filesystem_operator,
        grant: minted
      )
      assert_equal :approve, first.fetch(:answer)
      assert_equal :filesystem_operator, first.fetch(:actor_evidence)
      assert_equal minted.scope, first.fetch(:grant).scope

      replay = log.record_resolution(
        decision_id: decision_id,
        answer: :approve,
        scope: :session,
        actor_evidence: :filesystem_operator,
        grant: minted
      )
      assert_equal first.fetch(:grant).key, replay.fetch(:grant).key
      assert_equal first.fetch(:grant).created_at_ms, replay.fetch(:grant).created_at_ms

      error = assert_raises(Approval::ConflictingResolutionError) do
        log.record_resolution(
          decision_id: decision_id,
          answer: :deny,
          scope: nil,
          actor_evidence: nil,
          grant: nil
        )
      end
      assert_match(/already resolved/, error.message)

      resolution = log.lookup_resolution(decision_id)
      assert_equal :approve, resolution.fetch(:answer)
    end
  end

  def test_active_policy_round_trips_single_row
    with_adapter do |adapter|
      active = adapter.bind_approval_active_policy(clock: -> { Time.at(1_000) })

      assert_nil active.read
      active.write('/policies/base.yaml', 'rev-1')
      active.write('/policies/other.yaml', 'rev-2')

      rows = adapter.__send__(:read, operation: 'test.active_rows') do |txn|
        txn.scalar('test.active_rows', 'SELECT COUNT(*) FROM tamoz_approval_active_policy')
      end
      assert_equal 1, rows

      assert_equal({ path: '/policies/other.yaml', rev: 'rev-2' }, active.read)
    end
  end

  def test_stream_receipt_expiry_fails_closed
    with_adapter do |adapter|
      t0 = Time.utc(2026, 8, 23, 12, 0, 0)
      clock = -> { t0 }
      store = adapter.bind_approval_receipt_store(tenant: 'acme', clock: clock)

      created = store.reserve_requested(
        approval_id: 'a1',
        tenant_id: 'acme',
        payload_digest: 'digest',
        identity: { kind: 'telegram' },
        ttl_s: 60
      )
      assert_equal true, created
      refute_nil store.fetch('a1')

      store_with_later_clock = adapter.bind_approval_receipt_store(tenant: 'acme', clock: -> { t0 + 61 })
      assert_nil store_with_later_clock.fetch('a1'),
                 'an expired receipt must read as absent — fail closed'

      error = assert_raises(Tamoz::StoreConflictError) do
        store_with_later_clock.claim_delivery(approval_id: 'a1')
      end
      assert_match(/unknown approval/, error.message)
    end
  end

  private

  def decision_record(verdict: :ask)
    decision = Approval::Decision.new(
      id: 's1:rev-a:' + ('a' * 64),
      verdict: verdict,
      reason: 'tier local_execute default',
      rule_id: 'tier.local_execute',
      tier: :local_execute,
      grant_offer: Approval::GrantOffer.new(
        scopes: [:once, :session],
        key: { verb: :execute, tool: :run_check }
      ),
      required_evidence: :filesystem_operator,
      policy_rev: 'rev-a',
      session_id: 's1'
    )
    {
      decision_id: decision.id,
      step_scope: '',
      tool: 'run_check',
      verb: 'execute',
      tier: 'local_execute',
      rule_id: 'tier.local_execute',
      verdict: verdict.to_s,
      reason: 'tier local_execute default',
      evidence: 'filesystem_operator',
      policy_rev: 'rev-a',
      argv_digest: 'd' * 64,
      targets_digest: 'e' * 64,
      session_id: 's1',
      grant_scopes: [:once, :session],
      grant_key: { verb: 'execute', tool: 'run_check' },
      decision: decision
    }
  end
end
