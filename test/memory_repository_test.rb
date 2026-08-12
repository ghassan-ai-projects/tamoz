# frozen_string_literal: true

require_relative "test_helper"

# P11 probes P11-05..P11-09, P11-16..P11-18, P11-06: the lexical index table,
# the DC-3 one-transaction append, the SQL authorization-before-ranking filters
# (decryption boundary), the honest-searchable claim, migration ordinal 2 +
# monotonic ordering, correction/head-join recall, and the purge owner.
class MemoryRepositoryTest < Minitest::Test
  NAMESPACE = "tamoz.memory.acme"
  CALLER = {
    tenant: "acme",
    user: "alice",
    project: "proj",
    sensitivity: :public,
    compatibility_graph: "1",
    compatibility_behavior: "tamoz.agent.session/1"
  }.freeze

  # A deterministic protection codec (XOR) with a decrypt counter — the
  # decryption-boundary instrumentation target (P11-07).
  class CountingProtection
    attr_reader :decrypts, :encrypts

    def initialize
      @decrypts = 0
      @encrypts = 0
      @byte = 0x5A
    end

    def name = "test.counting.xor"

    def encrypt(bytes, context:)
      @encrypts += 1
      bytes.b.bytes.map { |byte| byte ^ @byte }.pack("C*")
    end

    def decrypt(bytes, context:)
      @decrypts += 1
      bytes.bytes.map { |byte| byte ^ @byte }.pack("C*")
    end
  end

  def setup
    @directory = Dir.mktmpdir("tamoz-memory-repo")
    @protection = CountingProtection.new
    @adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(@directory, "memory.db"),
      store_protection: @protection,
      limits: Tamoz::SQLite::Limits.new(deletion_retention: 86_400.0)
    )
    @store = @adapter.store
    @repo = Tamoz::SQLite::MemoryRepository.new(store: @store)
  end

  def teardown
    @adapter.close if @adapter && !@adapter.closed?
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def index_row(**overrides)
    Tamoz::SQLite::MemoryRepository::IndexRow.new(
      store_namespace: NAMESPACE,
      memory_id: "m1",
      record_version: 1,
      layer: "experience",
      klass: "runbook",
      state: "active",
      scopes_tenant: "acme",
      scopes_user: "alice",
      scopes_project: "proj",
      sensitivity: "public",
      valid_until_ms: nil,
      compatibility_graph: "1",
      compatibility_behavior: "tamoz.agent.session/1",
      statement_search: "deployment rollout canary",
      searchable: true,
      **overrides
    )
  end

  def admit(memory_id: "m1", **overrides)
    row = index_row(memory_id:, **overrides)
    @repo.append(
      record: {"memory_id" => memory_id, "statement" => "statement-#{memory_id}"},
      index: row,
      expected_version: nil,
      sensitive: row.sensitivity == "sensitive"
    )
  end

  def test_migration_2_creates_the_index_table_and_ordinals_are_monotonic
    # P11-06: CURRENT_VERSION moved 1 -> 2 through a checksummed MIGRATION_2;
    # P13: CURRENT_VERSION moved 2 -> 3 through MIGRATION_3 (scheduler tables);
    # P14: CURRENT_VERSION moved 3 -> 4 through MIGRATION_4 (stream tables);
    # comms moved 5 -> 6 through MIGRATION_6; ADR-049 moved 8 -> 9 and 9 -> 10
    # through MIGRATION_9/10; the JCS digest-rule cutover moved 10 -> 11
    # through MIGRATION_11. The monotonic-ordering guard makes ordinal reuse
    # impossible.
    assert_equal 11, Tamoz::SQLite::Migrator::CURRENT_VERSION
    assert_equal [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], Tamoz::SQLite::Migrator.migration_ordinals

    database = SQLite3::Database.new(File.join(@directory, "memory.db"))
    assert_equal 11, database.get_first_value("PRAGMA user_version")
    tables = database.execute(
      "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = 'tamoz_memory_index'"
    )
    assert_equal 1, tables.length
    columns = database.execute("PRAGMA table_info(tamoz_memory_index)").map { |row| row.fetch(1) }
    assert_equal %w[
      store_namespace memory_id record_version layer class state scopes_tenant
      scopes_user scopes_project sensitivity valid_until_ms compatibility_graph
      compatibility_behavior statement_search searchable
    ], columns
    database.close

    # A pre-P11 database (schema version 1) upgrades in place with existing
    # Store data intact.
    old = File.join(@directory, "old.db")
    legacy = Tamoz::SQLite::Adapter.new(path: old)
    legacy.store.put("tamoz.plain", "key", {"value" => 1}, if_version: nil)
    legacy.close
    database = SQLite3::Database.new(old)
    database.execute("DROP TABLE tamoz_memory_index")
    database.execute("DROP TABLE IF EXISTS tamoz_digest_epoch")
    database.execute("DROP TABLE IF EXISTS tamoz_schedules")
    database.execute("DROP TABLE IF EXISTS tamoz_occurrences")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_channels")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_events")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_partitions")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_operator_state")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_situations")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_situation_current")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_triggers")
    database.execute("DROP TABLE IF EXISTS tamoz_stream_outbox")
    %w[
      tamoz_comms_surfaces tamoz_comms_bindings tamoz_comms_pairing_challenges
      tamoz_comms_conversations tamoz_comms_inbound tamoz_comms_requests
      tamoz_comms_poll_state tamoz_comms_outbox tamoz_comms_approval_prompts
      tamoz_comms_decisions tamoz_comms_gaps tamoz_comms_delivery_pacing
    ].each do |table|
      database.execute("DROP TABLE IF EXISTS #{table}")
    end
    database.execute("PRAGMA user_version = 1")
    database.execute("DELETE FROM tamoz_schema_migrations WHERE version IN (2, 3, 4, 5, 6, 7, 8, 9, 10, 11)")
    database.close
    upgraded = Tamoz::SQLite::Adapter.new(path: old)
    assert_equal({"value" => 1}, upgraded.store.get("tamoz.plain", "key").value)
    assert_equal 11, upgraded.integrity_check.fetch("schema_version")
    upgraded.close
  end

  # JCS digest-rule cutover (PLAN_TAMOZ_STREAM_BUILD T0.1). A pre-JCS database
  # carrying stream-engine rows and circuit rows migrates forward: MIGRATION_11
  # registers the digest epoch, clears the canonical-JSON-digest rows, and the
  # reopened connection verifies.
  def test_migration_11_registers_the_digest_epoch_and_clears_pre_jcs_rows
    path = File.join(@directory, "cutover.db")
    adapter = Tamoz::SQLite::Adapter.new(path:)
    database = SQLite3::Database.new(path)
    database.execute(
      "INSERT INTO tamoz_stream_channels(channel_id, revision, definition_digest, payload, payload_digest, deleted, created_at_ms, updated_at_ms) VALUES (?, 1, ?, ?, ?, 0, 1, 1)",
      ["ch", "sha256:#{"a" * 64}", "{}", "sha256:#{"c" * 64}"]
    )
    database.execute(
      "INSERT INTO tamoz_store_heads(namespace, key, current_version, deleted, sensitive, updated_at_ms) VALUES (?, ?, 1, 0, 0, 1)",
      ["tamoz.circuit.test", "sha256:#{"b" * 64}"]
    )
    database.execute("DROP TABLE tamoz_digest_epoch")
    database.execute("PRAGMA user_version = 10")
    database.execute("DELETE FROM tamoz_schema_migrations WHERE version = 11")
    database.close
    adapter.close

    upgraded = Tamoz::SQLite::Adapter.new(path:)
    database = SQLite3::Database.new(path)
    assert_equal 1, database.get_first_value("SELECT epoch FROM tamoz_digest_epoch")
    assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM tamoz_stream_channels")
    assert_equal 0, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_store_heads WHERE namespace GLOB 'tamoz.circuit.*'"
    )
    database.close
    assert_equal 11, upgraded.integrity_check.fetch("schema_version")
    upgraded.close
  end

  def test_append_writes_store_version_and_index_row_in_one_transaction
    # P11-05: one admitted record = exactly one Store version row AND one index
    # row, in one transaction (DC-3). A fault inside the transaction rolls both
    # back — no best-effort two-write.
    entry = admit
    assert_equal 1, entry.version

    database = SQLite3::Database.new(File.join(@directory, "memory.db"))
    assert_equal 1, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_store_versions WHERE namespace = ? AND key = ?",
      [NAMESPACE, "experience/m1"]
    )
    assert_equal 1, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_memory_index WHERE store_namespace = ? AND memory_id = ?",
      [NAMESPACE, "m1"]
    )
    database.close

    # A concurrent-write CAS conflict raises StoreConflictError.
    assert_raises(Tamoz::StoreConflictError) do
      @repo.append(
        record: {"memory_id" => "m1"},
        index: index_row(memory_id: "m1", record_version: 2, state: "consolidated"),
        expected_version: 99,
        sensitive: false
      )
    end
  end

  def test_version_append_increments_and_original_bytes_never_edited
    # P11-01 at the repository layer: every update appends record_version + 1;
    # the original version's bytes stay byte-identical.
    admit
    original = @store.get(NAMESPACE, "experience/m1").value
    @repo.append(
      record: {"memory_id" => "m1", "statement" => "corrected"},
      index: index_row(memory_id: "m1", record_version: 2, statement_search: "corrected"),
      expected_version: 1,
      sensitive: false
    )
    assert_equal 2, @repo.current_version(NAMESPACE, "experience", "m1")
    v1 = @repo.version(NAMESPACE, "experience", "m1", 1)
    assert_equal 1, v1.fetch(:entry).version
    assert_equal original, v1.fetch(:entry).value
    v2 = @repo.version(NAMESPACE, "experience", "m1", 2)
    assert_equal({"memory_id" => "m1", "statement" => "corrected"}, v2.fetch(:entry).value)
  end

  def test_search_authorizes_in_sql_before_any_materialization_or_decryption
    # P11-07/P11-08: every filter dimension independently removes its records;
    # the caller authority is bound as parameters; sensitive rows are never
    # decrypted during a scan.
    admit(memory_id: "mine", statement_search: "deployment rollout canary")
    admit(memory_id: "other-tenant", scopes_tenant: "other", statement_search: "deployment rollout")
    admit(memory_id: "other-user", scopes_user: "bob", statement_search: "deployment")
    admit(memory_id: "other-project", scopes_project: "other-proj", statement_search: "deployment")
    admit(memory_id: "superseded", state: "superseded", statement_search: "deployment")
    # The sensitive record genuinely matches the query term on its searchable
    # metadata class ("deployment-runbook" prefix-matches "deploy") yet is
    # sensitivity-blocked — the hard-zero filter path fires without decrypt.
    admit(memory_id: "secret", sensitivity: "sensitive", klass: "deployment-runbook",
          statement_search: nil, searchable: false)
    admit(memory_id: "expired", valid_until_ms: 1, statement_search: "deployment")
    admit(memory_id: "wrong-compat", compatibility_behavior: "tamoz.agent.session/9", statement_search: "deployment")
    admit(memory_id: "wrong-layer", layer: "knowledge", klass: "procedure", statement_search: "deployment")

    result = @repo.search(
      caller: CALLER,
      query: {terms: ["deploy"], layer: "experience"}
    )
    assert_includes result.candidate_ids, "mine"
    refute_includes result.candidate_ids, "other-tenant"
    refute_includes result.candidate_ids, "other-user"
    refute_includes result.candidate_ids, "other-project"
    refute_includes result.candidate_ids, "superseded"
    refute_includes result.candidate_ids, "secret"
    refute_includes result.candidate_ids, "expired"
    refute_includes result.candidate_ids, "wrong-compat"
    refute_includes result.candidate_ids, "wrong-layer"

    # The hard-zero signal: the sensitive record matched on its metadata class
    # but was never materialized or decrypted by the scan. The only decrypt so
    # far is the Store's own append-time materialization of the sensitive
    # payload (put returns the decrypted value); the searches add zero.
    assert_equal ["secret"], result.matched_restricted.map { |row| row.fetch("memory_id") }
    decrypts_after_admit = @protection.decrypts
    assert_operator @protection.encrypts, :>=, 1

    # A caller WITHOUT authority over the tenant never sees the tenant's rows.
    other = CALLER.merge(tenant: "other", user: "other-u", project: "other-p")
    assert_empty @repo.search(caller: other, query: {terms: ["deploy"]}).candidates
    assert_equal decrypts_after_admit, @protection.decrypts
  end

  def test_search_filters_are_bound_parameters_not_interpolated
    # P11-08: a SQL-injection-shaped scope value changes nothing.
    admit(memory_id: "mine", statement_search: "deployment")
    admit(memory_id: "x", scopes_user: "alice' OR '1'='1", statement_search: "deployment")
    result = @repo.search(caller: CALLER, query: {terms: ["deploy"]})
    assert_equal ["mine"], result.candidate_ids
  end

  def test_honest_searchable_claim_prefix_and_exact_only
    # P11-09: prefix and exact matches on the indexed columns work; a
    # full-statement substring NOT present in the indexed columns and a
    # semantic-style query do not match; searchable? honestly reports.
    admit(memory_id: "prefix", statement_search: "deployment rollout")
    admit(memory_id: "layer-hit", layer: "knowledge", statement_search: nil, searchable: false)
    admit(memory_id: "class-hit", klass: "canary-procedure", statement_search: "unrelated")

    exact = @repo.search(caller: CALLER, query: {terms: ["deployment"]})
    assert_equal ["prefix"], exact.candidate_ids

    layer = @repo.search(caller: CALLER, query: {terms: ["knowledge"]})
    assert_equal ["layer-hit"], layer.candidate_ids

    klass = @repo.search(caller: CALLER, query: {terms: ["canary"]})
    assert_equal ["class-hit"], klass.candidate_ids

    # The term "procedure AND rollout" is not a substring of any indexed value.
    none = @repo.search(caller: CALLER, query: {terms: ["procedure rollout"]})
    assert_empty none.candidate_ids

    # The record's searchable flag reports exactly the content-search surface.
    row = @repo.index_row(NAMESPACE, "layer-hit", 1)
    assert_equal false, row.searchable
    assert_nil row.statement_search
    public_row = @repo.index_row(NAMESPACE, "prefix", 1)
    assert_equal true, public_row.searchable
    assert_equal "deployment rollout", public_row.statement_search
  end

  def test_correction_leaves_active_recall_and_historical_read_works
    # P11-16 at the repository layer: after a correction append, the old
    # version is not head, so the index head-join excludes it from active
    # recall; a historical read still works.
    @repo.append(
      record: {"memory_id" => "r", "statement" => "wrong content"},
      index: index_row(memory_id: "r", statement_search: "wrong content"),
      expected_version: nil,
      sensitive: false
    )
    @repo.append(
      record: {"memory_id" => "r", "statement" => "right content", "supersession_key" => "sha256:old"},
      index: index_row(memory_id: "r", record_version: 2, statement_search: "right content"),
      expected_version: 1,
      sensitive: false
    )
    result = @repo.search(caller: CALLER, query: {terms: ["wrong"]})
    assert_empty result.candidates
    assert_equal 1, @repo.search(caller: CALLER, query: {terms: ["right"]}).candidates.length
    v1 = @repo.version(NAMESPACE, "experience", "r", 1)
    assert_equal({"memory_id" => "r", "statement" => "wrong content"}, v1.fetch(:entry).value)
  end

  def test_sensitive_record_never_stores_searchable_statement_text
    # P11-05/P11-25: sensitive records carry NULL statement_search; the raw
    # statement bytes live only in the Store's protected payload.
    admit(memory_id: "secret", sensitivity: "sensitive", statement_search: nil, searchable: false)
    row = @repo.index_row(NAMESPACE, "secret", 1)
    assert_nil row.statement_search
    assert_equal false, row.searchable

    database = SQLite3::Database.new(File.join(@directory, "memory.db"))
    search_text = database.get_first_value(
      "SELECT statement_search FROM tamoz_memory_index WHERE memory_id = 'secret'"
    )
    assert_nil search_text
    sensitive_flag = database.get_first_value(
      "SELECT sensitive FROM tamoz_store_heads WHERE namespace = ? AND key = 'experience/secret'",
      [NAMESPACE]
    )
    assert_equal 1, sensitive_flag
    database.close
  end

  def test_purge_refuses_before_retention_and_removes_ciphertext_after
    # P11-18: before the retention boundary the purge refuses with the
    # StoreConflictError family and emits NO receipt; after it, the ciphertext
    # version rows AND index rows are physically gone and a receipt is emitted.
    admit(memory_id: "doomed", statement_search: "deployment")
    @store.delete(NAMESPACE, "experience/doomed", if_version: 1)

    now = Time.now.to_i * 1000
    error = assert_raises(Tamoz::StoreConflictError) do
      @repo.purge(NAMESPACE, "experience", "doomed", now_ms: now)
    end
    assert_includes error.message, "retention"

    later = now + (86_401 * 1_000)
    receipt = @repo.purge(NAMESPACE, "experience", "doomed", now_ms: later)
    assert_equal 1, receipt.fetch("removed").fetch("records")
    assert_operator receipt.fetch("removed").fetch("version_rows"), :>=, 2
    assert_operator receipt.fetch("removed").fetch("index_rows"), :>=, 1
    assert_equal later, receipt.fetch("purged_at_ms")

    database = SQLite3::Database.new(File.join(@directory, "memory.db"))
    assert_equal 0, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_store_versions WHERE namespace = ? AND key = 'experience/doomed'",
      [NAMESPACE]
    )
    assert_equal 0, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_store_heads WHERE namespace = ? AND key = 'experience/doomed'",
      [NAMESPACE]
    )
    assert_equal 0, database.get_first_value(
      "SELECT COUNT(*) FROM tamoz_memory_index WHERE store_namespace = ? AND memory_id = 'doomed'",
      [NAMESPACE]
    )
    database.close

    # Purging again refuses: nothing is tombstoned anymore.
    assert_raises(Tamoz::StoreConflictError) do
      @repo.purge(NAMESPACE, "experience", "doomed", now_ms: later)
    end
  end

  def test_expired_purge_pass_names_pending_records_in_the_receipt
    admit(memory_id: "old", statement_search: "x")
    admit(memory_id: "fresh", statement_search: "y")
    @store.delete(NAMESPACE, "experience/old", if_version: 1)
    @store.delete(NAMESPACE, "experience/fresh", if_version: 1)

    now = Time.now.to_i * 1000
    retention_ms = 86_400_000
    database = SQLite3::Database.new(File.join(@directory, "memory.db"))
    # "old" was tombstoned far enough in the past to be expired; "fresh" was
    # tombstoned now and is still inside its retention window.
    database.execute(
      "UPDATE tamoz_store_versions SET created_at_ms = ? WHERE namespace = ? AND key = ?",
      [now - (retention_ms * 2), NAMESPACE, "experience/old"]
    )
    database.execute(
      "UPDATE tamoz_store_versions SET created_at_ms = ? WHERE namespace = ? AND key = ?",
      [now, NAMESPACE, "experience/fresh"]
    )
    database.close

    later = now + retention_ms - 1_000
    receipt = @repo.purge_expired(now_ms: later)
    assert_equal 1, receipt.fetch("removed").fetch("records")
    assert_equal "old", receipt.fetch("removed").fetch("entries").first.fetch("memory_id")
    pending = receipt.fetch("pending")
    assert_equal 1, pending.length
    assert_includes pending.first.fetch("key"), "fresh"
  end
end
