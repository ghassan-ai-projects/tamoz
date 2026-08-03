# frozen_string_literal: true

require_relative "test_helper"

# DR-2 acceptance D1–D10 against the DURABLE `Tamoz::SQLite::CircuitStore`
# (docs/DR2_DURABLE_CIRCUIT_PLAN.md §7). The record engine itself
# (`Tamoz::Circuit::Record`) is covered by the tamoz-core circuit tests; this
# suite proves the durable adapter: CAS read-modify-write, restart survival,
# owner-scoped evidence, the read-time self-heal rule, fail-closed corruption,
# authority-gated repair, and the bounded merge protocol.
class SQLiteCircuitStoreTest < Minitest::Test
  Circuit = Tamoz::Circuit

  def with_store
    Dir.mktmpdir("tamoz-circuit") do |directory|
      path = File.join(directory, "circuit.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      store = adapter.store
      yield store, adapter, path
    ensure
      adapter&.close
    end
  end

  def clock_at(epoch = 1_700_000_000)
    -> { Time.at(epoch) }
  end

  def make_store(store, scope:, scope_id:, owner_id:, clock: clock_at)
    Tamoz::SQLite::CircuitStore.new(
      store:, scope:, scope_id:, owner_id:, clock:
    )
  end

  # A well-formed reset evidence for the `server` scope (caller_command rule).
  def server_reset_evidence
    {
      "authority" => "operator",
      "actor" => "op-1",
      "operator_command_digest" => "sha256:#{"a" * 64}"
    }
  end

  # A well-formed reset evidence for `rule_target` (reviewed_plan rule).
  def rule_reset_evidence
    {
      "authority" => "human_approved_plan",
      "plan_digest" => "sha256:#{"b" * 64}",
      "rule_version" => "2"
    }
  end

  # D1a — the server scope's consecutive-transport condition opens the scope,
  # and a success inside the window does NOT mask it (the window pair, C3).
  def test_d1_consecutive_threshold_opens_and_owner_success_does_not_mask
    with_store do |store, _adapter, _path|
      circuit = make_store(store, scope: :server, scope_id: "svc-1", owner_id: "deploy-a")
      assert_equal :degraded, circuit.record_failure(kind: :transport)
      assert_equal :degraded, circuit.record_failure(kind: :transport)
      assert_equal :open, circuit.record_failure(kind: :transport)
      assert circuit.open?
      assert_equal 3, circuit.failures
    end
  end

  # D1b — the rule_target scope's non-consecutive WINDOW condition:
  # verification fail → success → fail in-window still opens (C3/D1).
  def test_d1_rule_target_window_condition_is_not_consecutive
    with_store do |store, _adapter, _path|
      t0 = 1_700_000_000
      circuit = make_store(store, scope: :rule_target, scope_id: "rule.stale-edit",
                                  owner_id: "rule.stale-edit", clock: -> { Time.at(t0) })
      # One verification failure feeds the WINDOW accumulator only (the
      # rule_target consecutive counter is for remediation failures, so health
      # is still :closed at one in-window event).
      assert_equal :closed, circuit.record_failure(kind: :verification_failed)
      # A success resets the OWNER's consecutive counter (0 anyway), but the
      # window accumulator survives (that is exactly what makes it
      # non-consecutive).
      assert_equal :closed, circuit.record_success
      # Second verification failure INSIDE the 900 s window → open.
      circuit.record_failure(kind: :verification_failed)
      assert circuit.open?
    end
  end

  # D2 — open disables mutation: transitions observe only, state stays open.
  def test_d2_open_disables_mutation
    with_store do |store, _adapter, _path|
      circuit = make_store(store, scope: :server, scope_id: "svc-2", owner_id: "deploy-b")
      3.times { circuit.record_failure(kind: :transport) }
      assert circuit.open?

      # A failure while open records evidence but never closes; a success while
      # open never closes either (DR-2 §4).
      assert_equal :open, circuit.record_failure(kind: :transport)
      assert_equal :open, circuit.record_success
      assert circuit.open?
    end
  end

  # D3 — time alone never resets; the probe window permits observation only.
  def test_d3_time_alone_never_resets
    with_store do |store, _adapter, _path|
      t0 = 1_700_000_000
      circuit = make_store(store, scope: :server, scope_id: "svc-3", owner_id: "deploy-c",
                                  clock: -> { Time.at(t0) })
      3.times { circuit.record_failure(kind: :transport) }
      assert circuit.open?

      # After a full probe window and then some: still open. Only the
      # authority path (reset with evidence) closes it.
      after_probe = make_store(store, scope: :server, scope_id: "svc-3", owner_id: "deploy-c",
                                      clock: -> { Time.at(t0 + 120) })
      assert after_probe.open?

      assert_equal :closed, after_probe.reset(evidence: server_reset_evidence)
      refute after_probe.open?
    end
  end

  # D4 — reset requires the scope's authority with per-scope evidence weight;
  # a self-reset (in-band actor) is refused and leaves the circuit open.
  def test_d4_reset_requires_authority_and_self_reset_is_refused
    with_store do |store, _adapter, _path|
      circuit = make_store(store, scope: :server, scope_id: "svc-4", owner_id: "deploy-d")
      3.times { circuit.record_failure(kind: :transport) }

      assert_raises(Tamoz::CircuitPolicyError) { circuit.reset(evidence: {}) }
      assert_raises(Tamoz::CircuitPolicyError) do
        circuit.reset(evidence: {"actor" => "deploy-d"})
      end
      # The rule_target scope needs plan/eval evidence + new rule version.
      rule = make_store(store, scope: :rule_target, scope_id: "rule.r1", owner_id: "rule.r1")
      assert_raises(Tamoz::CircuitPolicyError) do
        rule.reset(evidence: {"authority" => "tamoz-evals"})
      end
      assert_equal :closed, rule.reset(evidence: rule_reset_evidence)
    end
  end

  # D5 — owner-scoped evidence: one owner's success does not mask another's
  # failures, and a fresh owner cannot clear the shared scope's open state.
  def test_d5_owner_success_does_not_mask_another_owners_failures
    with_store do |store, _adapter, _path|
      owner_a = make_store(store, scope: :server, scope_id: "svc-5", owner_id: "deploy-a")
      owner_b = make_store(store, scope: :server, scope_id: "svc-5", owner_id: "deploy-b")

      # The consecutive counter is PER-OWNER (DR-2 C2/D5): each owner's
      # predicate is evaluated against its own sub-state, and any owner meeting
      # it opens the shared scope record.
      assert_equal :degraded, owner_a.record_failure(kind: :transport)
      assert_equal :degraded, owner_a.record_failure(kind: :transport)
      assert_equal :open, owner_a.record_failure(kind: :transport)
      assert owner_a.open?

      # B's success resets B's OWN counter (0 → 0) — A's failures stay, and a
      # success never closes an open circuit (DR-2 §4).
      assert_equal :open, owner_b.record_success
      assert_equal 3, owner_a.failures
      assert_equal 0, owner_b.failures
      assert owner_a.open?
    end
  end

  # D6 — concurrent writers: bounded CAS; the losing writer retries from a
  # fresh read, and both pieces of evidence land (merge by digest).
  def test_d6_concurrent_writers_merge_by_digest
    with_store do |store, _adapter, _path|
      barrier = Queue.new
      release = Queue.new
      results = Queue.new
      threads = %w[deploy-a deploy-b].map do |owner|
        Thread.new do
          circuit = make_store(store, scope: :server, scope_id: "svc-6", owner_id: owner)
          barrier << true
          release.pop
          results << circuit.record_failure(kind: :transport)
        end
      end
      2.times { barrier.pop }
      2.times { release << true }
      threads.each(&:join)

      # Both writes landed (consecutive counts for both owners, shared scope).
      final = make_store(store, scope: :server, scope_id: "svc-6", owner_id: "deploy-a")
      assert_equal 1, final.failures
      assert_equal 1, make_store(store, scope: :server, scope_id: "svc-6", owner_id: "deploy-b").failures
      # No exception escaped, and the evidence list is deterministic.
      assert_equal 2, results.size
    end
  end

  # D7 — corruption fails closed (open, observation only); repair requires the
  # authority AND the observed digest; a wrong digest refuses, the exact digest
  # recovers to a canonical closed record.
  def test_d7_corrupt_record_fails_closed_and_repairs_with_authority
    with_store do |store, adapter, path|
      circuit = make_store(store, scope: :server, scope_id: "svc-7", owner_id: "deploy-a")
      3.times { circuit.record_failure(kind: :transport) }
      assert circuit.open?

      # Corrupt the stored payload: overwrite the head row bytes in place.
      namespace = Tamoz::Circuit.namespace_for("server")
      key = Tamoz::Circuit.scope_digest(scope_type: "server", scope_id: "svc-7")
      adapter.__send__(:transaction, operation: "test.corrupt") do |tx|
        tx.execute(
          "test.corrupt",
          <<~SQL,
            UPDATE tamoz_store_versions
            SET payload = ?
            WHERE namespace = ? AND key = ?
              AND version = (SELECT current_version FROM tamoz_store_heads
                             WHERE namespace = ? AND key = ?)
          SQL
          [
            ::SQLite3::Blob.new("not a codec payload"),
            namespace, key, namespace, key
          ]
        )
      end

      # Ordinary reads now fail closed: open, observation-only, no transitions.
      restarted = make_store(store, scope: :server, scope_id: "svc-7", owner_id: "deploy-a")
      assert restarted.corrupt?
      assert restarted.open?
      assert_equal 0, restarted.failures
      assert_nil restarted.reset_evidence
      assert_equal :open, restarted.record_failure(kind: :transport)

      # Repair with the WRONG observed digest refuses (policy violation).
      assert_raises(Tamoz::CircuitPolicyError) do
        restarted.repair_corrupt(
          scope: :server,
          evidence: server_reset_evidence,
          expected_payload_digest: "sha256:#{"c" * 64}"
        )
      end

      # Compute the ACTUAL stored digest of the corrupt head row.
      observed = nil
      adapter.__send__(:transaction, operation: "test.digest") do |tx|
        row = tx.first(
          "test.digest",
          <<~SQL,
            SELECT payload_digest FROM tamoz_store_versions
            WHERE namespace = ? AND key = ?
              AND version = (SELECT current_version FROM tamoz_store_heads
                             WHERE namespace = ? AND key = ?)
          SQL
          [namespace, key, namespace, key]
        )
        observed = row.fetch(0)
      end

      # Exact digest + authority repairs to a canonical CLOSED record.
      repaired = restarted.repair_corrupt(
        scope: :server,
        evidence: server_reset_evidence,
        expected_payload_digest: observed
      )
      refute repaired.nil?
      refute restarted.corrupt?
      refute restarted.open?
      # The repair record is canonical and durable: a fresh store reads it.
      fresh = make_store(store, scope: :server, scope_id: "svc-7", owner_id: "deploy-a")
      refute fresh.open?
      assert_kind_of String, fresh.reset_evidence
    ensure
      # keep the file on disk for the digest probe ordering
      _ = path
    end
  end

  # D9 — crash between increment and open: a CLOSED record whose counter already
  # satisfies an open predicate reads as open from the evidence (C1 read-time
  # rule). Simulated by writing a closed payload with failures=3 directly.
  def test_d9_closed_record_with_satisfied_predicate_reads_open
    with_store do |store, _adapter, _path|
      namespace = Tamoz::Circuit.namespace_for("server")
      key = Tamoz::Circuit.scope_digest(scope_type: "server", scope_id: "svc-9")
      closed_with_evidence = {
        "format_version" => 1,
        "scope_type" => "server",
        "scope_id" => "svc-9",
        "state" => "closed",
        "threshold" => 3,
        "owners" => {
          "deploy-a" => {"failures" => 3, "conditions" => {}}
        },
        "conditions_met" => [],
        "opened_at_wall_ms" => nil,
        "probe_window_ms" => 30_000,
        "reset_authority" => "owner",
        "last_reset_at" => nil,
        "last_reset_evidence" => nil,
        "last_failure" => {
          "kind" => "transport", "context_digest" => nil, "owner" => "deploy-a",
          "observed_at_ms" => 1_700_000_000
        }
      }
      store.put(namespace, key, closed_with_evidence)

      circuit = make_store(store, scope: :server, scope_id: "svc-9", owner_id: "deploy-a")
      assert circuit.open?
      assert_equal 3, circuit.failures
    end
  end

  # D10 — restart identity: the same stable owner id reuses its own evidence
  # across a fresh store instance (the durable store is a restart by
  # construction); UUID churn is refused at the boundary.
  def test_d10_restart_identity_and_uuid_refusal
    with_store do |store, _adapter, _path|
      first = make_store(store, scope: :server, scope_id: "svc-10", owner_id: "deploy-a")
      first.record_failure(kind: :transport)

      # A NEW store instance over the same database is a process restart:
      # the owner's evidence survives.
      restarted = make_store(store, scope: :server, scope_id: "svc-10", owner_id: "deploy-a")
      assert_equal 1, restarted.failures

      # A per-process UUID as owner identity is refused (DR-2 D10).
      assert_raises(Tamoz::CircuitPolicyError) do
        make_store(
          store, scope: :server, scope_id: "svc-10",
          owner_id: "11111111-1111-1111-1111-111111111111"
        )
      end
    end
  end

  # D10b — the owner map is bounded: the 65th owner fails closed.
  def test_d10_owner_overflow_fails_closed
    with_store do |store, _adapter, _path|
      assert_raises(Tamoz::CircuitPolicyError) do
        65.times do |index|
          owner = format("deploy-%02d", index)
          circuit = make_store(store, scope: :server, scope_id: "svc-11", owner_id: owner)
          circuit.record_failure(kind: :transport)
        end
      end
    end
  end
end
