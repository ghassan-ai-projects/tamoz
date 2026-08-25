# frozen_string_literal: true

require "json"

module Tamoz
  module SQLite
    # P11 (three-layer memory) — the `tamoz-sqlite`-owned structural memory
    # repository (plan §2 package boundary, DC-3 atomic storage seam).
    #
    # `tamoz-agent` owns the record, admission, authorization, and retrieval
    # SEMANTICS; this class owns the STORAGE CONTRACT and nothing else:
    #
    # * `append` writes the Store version/head AND the lexical index row in ONE
    #   transaction (DC-3): public `Store#put` cannot be nested inside a second
    #   transaction that also updates the index, so the repository uses the
    #   Store's shared internal append primitive inside the one transaction it
    #   owns. A kill between the two writes leaves neither.
    # * `search` filters on scope ∩ layer/class ∩ eligible state ∩ sensitivity
    #   ≤ caller ∩ validity ∩ compatibility in SQL BEFORE any row is
    #   materialized or decrypted (invariant 30, plan §4 P11-B). Caller
    #   authority is bound into the query as parameters; the ranker and model
    #   never see an unauthorized candidate.
    # * `purge` physically removes ciphertext version rows + index rows after
    #   the retention boundary (invariant 31, plan §4 P11-D2, C6) and emits an
    #   invariant-54-shape receipt.
    #
    # The index stores ONLY searchable metadata columns plus memory id/version:
    # `statement_search` is populated only for non-sensitive records, so a
    # sensitive statement never enters a searchable column (invariant 24).
    class MemoryStore
      MEMORY_NAMESPACE_PREFIX = "tamoz.memory."
      SENSITIVITY_ORDER = %w[public internal sensitive].freeze
      MAX_LIMIT = 100_000

      # One immutable index row per Store version of a memory record.
      IndexRow = Data.define(
        :store_namespace, :memory_id, :record_version, :layer, :klass, :state,
        :scopes_tenant, :scopes_user, :scopes_project, :sensitivity,
        :valid_until_ms, :compatibility_graph, :compatibility_behavior,
        :statement_search, :searchable,
        :scopes_situation_type, :scopes_entity_type, :scopes_entity_id
      ) do
        def initialize(store_namespace:, memory_id:, record_version:, layer:, klass:, state:,
                       scopes_tenant:, scopes_user:, scopes_project:, sensitivity:,
                       valid_until_ms:, compatibility_graph:, compatibility_behavior:,
                       statement_search:, searchable:,
                       scopes_situation_type: nil, scopes_entity_type: nil, scopes_entity_id: nil)
          super
        end

        def key
          "#{layer}/#{memory_id}"
        end

        # The eval harness's fixture-shaped metadata projection.
        def to_h
          {
            "store_namespace" => store_namespace,
            "memory_id" => memory_id,
            "record_version" => record_version,
            "layer" => layer,
            "class" => klass,
            "state" => state,
            "scopes_tenant" => scopes_tenant,
            "scopes_user" => scopes_user,
            "scopes_project" => scopes_project,
            "sensitivity" => sensitivity,
            "valid_until_ms" => valid_until_ms,
            "compatibility_graph" => compatibility_graph,
            "compatibility_behavior" => compatibility_behavior,
            "statement_search" => statement_search,
            "searchable" => searchable,
            "scopes_situation_type" => scopes_situation_type,
            "scopes_entity_type" => scopes_entity_type,
            "scopes_entity_id" => scopes_entity_id
          }
        end
      end

      # The authorized retrieval result: `candidates` are rows that passed every
      # authorization filter AND the match clause; `matched_restricted` are rows
      # that matched the searchable dimensions but are sensitivity-blocked
      # (sensitivity `sensitive` — the hard-zero filter path fired, they were
      # never materialized or decrypted).
      SearchResult = Data.define(:candidates, :matched_restricted) do
        def initialize(candidates: [], matched_restricted: [])
          super(
            candidates: candidates.freeze,
            matched_restricted: matched_restricted.freeze
          )
        end

        def candidate_ids
          candidates.map { |row| row.fetch("memory_id") }
        end
      end

      attr_reader :store

      def initialize(store:, clock: -> { Time.now })
        unless store.is_a?(Store)
          raise ConfigurationError, "MemoryStore requires a Tamoz::SQLite::Store"
        end

        @store = store
        @clock = clock
        freeze
      end

      def now_ms
        @clock.call.to_i * 1000
      end

      # DC-3: ONE transaction for the Store version/head append AND the index
      # row. `record` is the canonical record value (a Hash or a registered
      # codec object), `index` is the IndexRow metadata, `expected_version` is
      # the CAS base (nil for a brand-new memory id). Returns the StoreEntry.
      def append(record:, index:, expected_version:, sensitive:)
        unless index.is_a?(IndexRow)
          raise ConfigurationError, "MemoryStore append requires an IndexRow"
        end
        bytes = store.state_codec.dump(record)
        stored = sensitive ? store.protect_bytes(bytes, namespace: index.store_namespace, key: index.key) : bytes
        entry = nil
        store.open_transaction(label: "memory.append") do |tx|
          entry, = store.append_in_transaction(
            tx,
            namespace: index.store_namespace,
            key: index.key,
            expected: expected_version,
            bytes: stored,
            sensitive:,
            deleted: false
          )
          tx.execute(
            "memory.index.upsert",
            <<~SQL,
              INSERT INTO tamoz_memory_index(
                store_namespace, memory_id, record_version, layer, class, state,
                scopes_tenant, scopes_user, scopes_project, sensitivity,
                valid_until_ms, compatibility_graph, compatibility_behavior,
                statement_search, searchable,
                scopes_situation_type, scopes_entity_type, scopes_entity_id
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(store_namespace, memory_id, record_version) DO UPDATE SET
                layer = excluded.layer,
                class = excluded.class,
                state = excluded.state,
                scopes_tenant = excluded.scopes_tenant,
                scopes_user = excluded.scopes_user,
                scopes_project = excluded.scopes_project,
                sensitivity = excluded.sensitivity,
                valid_until_ms = excluded.valid_until_ms,
                compatibility_graph = excluded.compatibility_graph,
                compatibility_behavior = excluded.compatibility_behavior,
                statement_search = excluded.statement_search,
                searchable = excluded.searchable,
                scopes_situation_type = excluded.scopes_situation_type,
                scopes_entity_type = excluded.scopes_entity_type,
                scopes_entity_id = excluded.scopes_entity_id
            SQL
            index_row_binds(index)
          )
        end
        entry
      rescue CheckpointCorruptionError => error
        raise StoreError.new("Store value could not be decoded"), cause: error
      end

      # The current record for a memory key (head version), or nil.
      def fetch(store_namespace, layer, memory_id)
        entry = store.get(store_namespace, "#{layer}/#{memory_id}")
        return nil unless entry

        {entry: entry, index: index_row(store_namespace, memory_id, entry.version)}
      end

      # One specific historical version of a record, or nil. The correction link
      # carries the prior version digest, so the agent never NEEDS this for
      # correction; it exists so a corrected record's prior content stays
      # readable (probe P11-16).
      def version(store_namespace, layer, memory_id, record_version)
        entry = store.read_version(store_namespace, "#{layer}/#{memory_id}", record_version)
        return nil unless entry

        {entry: entry, index: index_row(store_namespace, memory_id, record_version)}
      end

      # The current Store head version of a memory key, or nil.
      def current_version(store_namespace, layer, memory_id)
        store.head_version(store_namespace, "#{layer}/#{memory_id}")
      end

      # Authorization-before-ranking retrieval (invariant 30). All caller
      # authority is bound as SQL parameters; a candidate that fails any filter
      # never reaches the caller. The match clause is exact/prefix matching on
      # the indexed columns (`statement_search`, `layer`, `class`) — no
      # full-statement substring, no semantic/vector search (probe P11-09).
      #
      # caller: {tenant:, user:, project:, sensitivity:, compatibility_graph:,
      #          compatibility_behavior:}
      # query:  {terms: [String], layer: String|nil, klass: String|nil}
      def search(caller:, query: {terms: []}, limit: MAX_LIMIT)
        normalized_limit = validate_limit(limit)
        caller_values = validate_caller!(caller)
        namespace = "#{MEMORY_NAMESPACE_PREFIX}#{caller_values.fetch(:tenant)}"
        terms, layer, klass = validate_query!(query)
        as_of_ms = now_ms()
        allowed_sensitivities = sensitivity_at_most(caller_values.fetch(:sensitivity))

        binds = [
          namespace, caller_values.fetch(:tenant), caller_values.fetch(:user),
          caller_values.fetch(:project),
          *allowed_sensitivities,
          caller_values.fetch(:compatibility_graph),
          caller_values.fetch(:compatibility_behavior),
          as_of_ms
        ]
        # T0.3 situation boundary: a situation-scoped caller retrieves only
        # rows of the same entity type (default relatedness authority: same
        # tenant AND same entity type); an ordinary caller never sees rows in
        # the situation dimension. Both sides are explicit — zero cross-
        # boundary recall either way.
        situation_filter, situation_binds =
          situation_boundary(caller_values)
        matches_sql, match_binds = match_clause(terms, layer, klass)
        rows = nil
        store.open_transaction(label: "memory.search") do |tx|
          rows = tx.rows(
            "memory.search",
            <<~SQL,
              SELECT i.memory_id, i.record_version, i.layer, i.class, i.state,
                     i.scopes_tenant, i.scopes_user, i.scopes_project,
                     i.sensitivity, i.valid_until_ms, i.compatibility_graph,
                     i.compatibility_behavior, i.searchable,
                     i.scopes_situation_type, i.scopes_entity_type, i.scopes_entity_id
              FROM tamoz_memory_index i
              JOIN tamoz_store_heads h
                ON h.namespace = i.store_namespace
               AND h.key = i.layer || '/' || i.memory_id
               AND h.current_version = i.record_version
               AND h.deleted = 0
              WHERE i.store_namespace = ?
                AND i.state IN ('active', 'consolidated')
                AND i.scopes_tenant = ?
                AND i.scopes_user = ?
                AND i.scopes_project = ?
                AND i.sensitivity IN (#{sensitivity_placeholders(allowed_sensitivities)})
                AND i.compatibility_graph = ?
                AND i.compatibility_behavior = ?
                AND (i.valid_until_ms IS NULL OR i.valid_until_ms >= ?)
                #{situation_filter}
                #{matches_sql}
              ORDER BY i.layer, i.memory_id, i.record_version DESC
              LIMIT ?
            SQL
            [*binds, *situation_binds, *match_binds, normalized_limit]
          )
        end
        candidates = rows.map { |row| index_row_from_row(row).to_h }.freeze

        restricted = if terms.empty? && layer.nil? && klass.nil?
                       []
                     else
                       scan_matched_restricted(
                         namespace, caller_values, terms, layer, klass, as_of_ms
                       )
                     end
        SearchResult.new(candidates:, matched_restricted: restricted)
      end

      # Reads one index row (metadata only, never materialized).
      def index_row(store_namespace, memory_id, record_version)
        row = nil
        store.open_transaction(label: "memory.index_row") do |tx|
          row = tx.first(
            "memory.index_row",
            <<~SQL,
              SELECT store_namespace, memory_id, record_version, layer, class,
                     state, scopes_tenant, scopes_user, scopes_project,
                     sensitivity, valid_until_ms, compatibility_graph,
                     compatibility_behavior, statement_search, searchable,
                     scopes_situation_type, scopes_entity_type, scopes_entity_id
              FROM tamoz_memory_index
              WHERE store_namespace = ? AND memory_id = ? AND record_version = ?
            SQL
            [store_namespace, memory_id, record_version]
          )
        end
        return nil unless row

        IndexRow.new(
          store_namespace: row.fetch(0),
          memory_id: row.fetch(1),
          record_version: row.fetch(2),
          layer: row.fetch(3),
          klass: row.fetch(4),
          state: row.fetch(5),
          scopes_tenant: row.fetch(6),
          scopes_user: row.fetch(7),
          scopes_project: row.fetch(8),
          sensitivity: row.fetch(9),
          valid_until_ms: row.fetch(10),
          compatibility_graph: row.fetch(11),
          compatibility_behavior: row.fetch(12),
          statement_search: row.fetch(13),
          searchable: row.fetch(14) == 1,
          scopes_situation_type: row.fetch(15),
          scopes_entity_type: row.fetch(16),
          scopes_entity_id: row.fetch(17)
        )
      end

      # P11-D2 (C6): the tamoz-agent-orchestrated hard-purge. The sqlite
      # repository — never agent code reaching into tables — physically removes
      # the ciphertext version rows AND the index rows of one deleted memory
      # record after its retention window expired, and emits an invariant-54
      # shape receipt. Before the retention boundary the purge refuses with the
      # StoreConflictError family and emits NO receipt.
      def purge(store_namespace, layer, memory_id, now_ms: nil)
        now_ms ||= now_ms()
        key = "#{layer}/#{memory_id}"
        receipt = nil
        store.open_transaction(label: "memory.purge") do |tx|
          tombstone = tx.first(
            "memory.purge.tombstone",
            <<~SQL,
              SELECT v.created_at_ms
              FROM tamoz_store_heads h
              JOIN tamoz_store_versions v
                ON v.namespace = h.namespace
               AND v.key = h.key
               AND v.version = h.current_version
              LEFT JOIN tamoz_memory_index i
                ON i.store_namespace = h.namespace
               AND i.memory_id = substr(h.key, instr(h.key, '/') + 1)
               AND i.record_version = h.current_version
              WHERE h.namespace = ? AND h.key = ?
                AND (h.deleted = 1 OR i.state = 'deleted')
            SQL
            [store_namespace, key]
          )
          unless tombstone
            raise StoreConflictError, "memory record #{store_namespace}/#{key} is not tombstoned"
          end
          if now_ms < tombstone.fetch(0) + retention_ms
            raise StoreConflictError,
                  "memory record retention window has not expired for #{store_namespace}/#{key}"
          end

          tx.execute(
            "memory.purge.versions",
            <<~SQL,
              DELETE FROM tamoz_store_versions
              WHERE namespace = ? AND key = ?
            SQL
            [store_namespace, key]
          )
          version_rows = tx.changes
          tx.execute(
            "memory.purge.head",
            <<~SQL,
              DELETE FROM tamoz_store_heads
              WHERE namespace = ? AND key = ?
            SQL
            [store_namespace, key]
          )
          tx.execute(
            "memory.purge.index",
            <<~SQL,
              DELETE FROM tamoz_memory_index
              WHERE store_namespace = ? AND memory_id = ?
            SQL
            [store_namespace, memory_id]
          )
          index_rows = tx.changes
          receipt = build_receipt(
            store_namespace, memory_id, now_ms,
            removed: {"records" => 1, "version_rows" => version_rows, "index_rows" => index_rows},
            retained: {"protected_artifacts" => 0, "backups" => 0},
            pending: []
          )
        end
        receipt
      end

      # The batch purge pass: selects every expired memory tombstone, removes it,
      # and returns one receipt naming removed / retained / pending. Keys still
      # inside their retention window are named `pending`, never removed and
      # never reported as removed.
      def purge_expired(now_ms: now_ms())
        expired = expired_tombstones(now_ms:)
        still_pending = pending_tombstones(now_ms:)
        removed = expired.map do |namespace, key, memory_id, _deleted_at|
          purge(namespace, *key.split("/", 2), now_ms:)
          {"namespace" => namespace, "memory_id" => memory_id, "key" => key}
        end
        {
          "memory_purge_receipt" => 1,
          "purged_at_ms" => now_ms,
          "removed" => {"records" => removed.length, "entries" => removed},
          "retained" => {"protected_artifacts" => 0, "backups" => 0},
          "pending" => still_pending
        }.freeze
      end

      private

      # Head-eligible rows that matched the searchable dimensions but carry
      # sensitivity `sensitive` — the hard-zero signal that the filter path
      # fired without any materialization or decryption (invariant 24/30). The
      # same caller authority as `search` applies: the signal must not cross
      # the situation boundary, the user/project scope, or the eligible-state
      # set (otherwise it becomes an existence oracle for the far side).
      def scan_matched_restricted(namespace, caller_values, terms, layer, klass, now_ms)
        matches_sql, match_binds = match_clause(terms, layer, klass)
        situation_filter, situation_binds =
          situation_boundary(caller_values)
        rows = nil
        store.open_transaction(label: "memory.search.restricted") do |tx|
          rows = tx.rows(
            "memory.search.restricted",
            <<~SQL,
              SELECT i.memory_id, i.record_version, i.layer, i.class, i.state,
                     i.scopes_tenant, i.scopes_user, i.scopes_project,
                     i.sensitivity, i.valid_until_ms
              FROM tamoz_memory_index i
              JOIN tamoz_store_heads h
                ON h.namespace = i.store_namespace
               AND h.key = i.layer || '/' || i.memory_id
               AND h.current_version = i.record_version
               AND h.deleted = 0
              WHERE i.store_namespace = ?
                AND i.state IN ('active', 'consolidated')
                AND i.scopes_tenant = ?
                AND i.scopes_user = ?
                AND i.scopes_project = ?
                AND i.sensitivity = 'sensitive'
                AND i.compatibility_graph = ?
                AND i.compatibility_behavior = ?
                AND (i.valid_until_ms IS NULL OR i.valid_until_ms >= ?)
                #{situation_filter}
                #{matches_sql}
              ORDER BY i.layer, i.memory_id, i.record_version DESC
            SQL
            [
              namespace,
              caller_values.fetch(:tenant), caller_values.fetch(:user),
              caller_values.fetch(:project), caller_values.fetch(:compatibility_graph),
              caller_values.fetch(:compatibility_behavior), now_ms,
              *situation_binds, *match_binds
            ]
          )
        end
        rows.map do |row|
          {
            "memory_id" => row.fetch(0),
            "record_version" => row.fetch(1),
            "layer" => row.fetch(2),
            "class" => row.fetch(3),
            "state" => row.fetch(4),
            "sensitivity" => row.fetch(8)
          }
        end.freeze
      end

      def build_receipt(store_namespace, memory_id, now_ms, removed:, retained:, pending:)
        {
          "memory_purge_receipt" => 1,
          "namespace" => store_namespace,
          "memory_id" => memory_id,
          "removed" => removed,
          "retained" => retained,
          "pending" => pending,
          "purged_at_ms" => now_ms
        }.freeze
      end

      # The tombstone scan shared by the retention passes: heads ⋈ versions ⟕
      # index for every memory-namespaced key whose head is store-deleted or
      # agent-deleted. Callers own the transaction, statement label, and
      # retention comparison.
      def tombstone_query
        [
          <<~SQL,
            SELECT h.namespace, h.key, v.created_at_ms
            FROM tamoz_store_heads h
            JOIN tamoz_store_versions v
              ON v.namespace = h.namespace
             AND v.key = h.key
             AND v.version = h.current_version
            LEFT JOIN tamoz_memory_index i
              ON i.store_namespace = h.namespace
             AND i.memory_id = substr(h.key, instr(h.key, '/') + 1)
             AND i.record_version = h.current_version
            WHERE h.namespace LIKE ?
              AND (h.deleted = 1 OR i.state = 'deleted')
            ORDER BY h.namespace, h.key
          SQL
          ["#{MEMORY_NAMESPACE_PREFIX}%"]
        ]
      end

      def retention_ms
        (store.adapter.limits.deletion_retention * 1_000).ceil
      end

      # Tombstoned memory keys whose retention window has expired, with their
      # tombstone times. Returns [[store_namespace, key, memory_id, deleted_at_ms], ...].
      def expired_tombstones(now_ms: now_ms())
        rows = nil
        store.open_transaction(label: "memory.tombstones") do |tx|
          sql, binds = tombstone_query
          rows = tx.rows("memory.tombstones", sql, binds)
        end
        # P11 critic defect 2: matches BOTH store-tombstoned heads (h.deleted = 1,
        # the manual Store#delete path) AND agent-deleted records (index state
        # 'deleted' at the head version — the Lifecycle#delete path), so an
        # agent-deleted record's ciphertext can actually be purged (inv 31).
        rows.filter_map do |row|
          next unless row.fetch(2) && now_ms >= row.fetch(2) + retention_ms

          namespace = row.fetch(0)
          key = row.fetch(1)
          layer, memory_id = key.split("/", 2)
          [namespace, key, memory_id, row.fetch(2)]
        end.freeze
      end

      def pending_tombstones(now_ms: now_ms())
        rows = nil
        store.open_transaction(label: "memory.pending") do |tx|
          sql, binds = tombstone_query
          rows = tx.rows("memory.pending", sql, binds)
        end
        rows.filter_map do |row|
          next unless row.fetch(2) && now_ms < row.fetch(2) + retention_ms

          {
            "namespace" => row.fetch(0),
            "key" => row.fetch(1),
            "retention_expires_at_ms" => row.fetch(2) + retention_ms
          }
        end.freeze
      end

      def index_row_binds(index)
        [
          index.store_namespace, index.memory_id, index.record_version,
          index.layer, index.klass, index.state,
          index.scopes_tenant, index.scopes_user, index.scopes_project,
          index.sensitivity, index.valid_until_ms,
          index.compatibility_graph, index.compatibility_behavior,
          index.statement_search, index.searchable ? 1 : 0,
          index.scopes_situation_type, index.scopes_entity_type, index.scopes_entity_id
        ]
      end

      def index_row_from_row(row)
        IndexRow.new(
          store_namespace: nil,
          memory_id: row.fetch(0),
          record_version: row.fetch(1),
          layer: row.fetch(2),
          klass: row.fetch(3),
          state: row.fetch(4),
          scopes_tenant: row.fetch(5),
          scopes_user: row.fetch(6),
          scopes_project: row.fetch(7),
          sensitivity: row.fetch(8),
          valid_until_ms: row.fetch(9),
          compatibility_graph: row.fetch(10),
          compatibility_behavior: row.fetch(11),
          statement_search: nil,
          searchable: row.fetch(12) == 1,
          scopes_situation_type: row.fetch(13),
          scopes_entity_type: row.fetch(14),
          scopes_entity_id: row.fetch(15)
        )
      end

      def validate_caller!(caller)
        unless caller.is_a?(Hash)
          raise ConfigurationError, "memory search requires a caller hash"
        end
        tenant = validate_text(caller.fetch(:tenant), "caller tenant")
        user = validate_text(caller.fetch(:user), "caller user")
        project = validate_text(caller.fetch(:project), "caller project")
        sensitivity = caller.fetch(:sensitivity).to_s
        unless SENSITIVITY_ORDER.include?(sensitivity)
          raise ConfigurationError, "caller sensitivity must be one of #{SENSITIVITY_ORDER.join(", ")}"
        end
        graph = validate_text(caller.fetch(:compatibility_graph), "caller compatibility graph")
        behavior = validate_text(caller.fetch(:compatibility_behavior), "caller compatibility behavior")
        situation_type, entity_type, entity_id = validate_situation_identity!(caller)
        {
          tenant:, user:, project:, sensitivity:,
          compatibility_graph: graph, compatibility_behavior: behavior,
          situation_type:, entity_type:, entity_id:
        }
      end

      # T0.3: the situation authority accepts both key conventions (symbols
      # and strings) and requires the identity complete BY VALUE — a nil or
      # empty entity key cannot silently widen or narrow the boundary. The
      # values are normalized like the other caller fields (bounded, no
      # empty strings).
      def validate_situation_identity!(caller)
        situation_type = caller[:situation_type] || caller["situation_type"]
        entity_type = caller[:entity_type] || caller["entity_type"]
        entity_id = caller[:entity_id] || caller["entity_id"]
        if situation_type || entity_type || entity_id
          situation_type = validate_text(situation_type, "caller situation_type")
          entity_type = validate_text(entity_type, "caller entity_type")
          entity_id = validate_text(entity_id, "caller entity_id")
        end
        present = [situation_type, entity_type, entity_id].compact
        unless present.empty? || present.length == 3
          raise ConfigurationError,
                "caller situation identity must be complete: situation_type, entity_type, entity_id"
        end
        [situation_type, entity_type, entity_id]
      end

      # The T0.3 situation boundary as SQL: same entity type for a
      # situation-scoped caller, nothing from the situation dimension for an
      # ordinary caller. `situation_type` and `entity_id` are validated caller
      # identity (metadata for the episode), but only `entity_type` binds —
      # the default relatedness authority is "same tenant AND same entity
      # type"; the boundary widens per config only when a later phase adds an
      # entity_id or situation_type term to this fragment.
      def situation_boundary(caller_values)
        if caller_values.fetch(:entity_type)
          [
            "AND i.scopes_situation_type = ? AND i.scopes_entity_type = ?",
            [caller_values.fetch(:situation_type), caller_values.fetch(:entity_type)]
          ]
        else
          ["AND i.scopes_situation_type IS NULL AND i.scopes_entity_type IS NULL", []]
        end
      end

      def validate_query!(query)
        unless query.is_a?(Hash)
          raise ConfigurationError, "memory search requires a query hash"
        end
        terms = Array(query.fetch(:terms, [])).first(64).map do |term|
          validate_text(term, "search term")
        end.reject(&:empty?)
        layer = query[:layer] && validate_text(query[:layer], "layer filter")
        klass = query[:class] && validate_text(query[:class], "class filter")
        [terms.freeze, layer, klass]
      end

      def validate_text(value, name)
        text = SafeText.normalize(
          value,
          name:,
          max_bytes: 1_024,
          error_class: ConfigurationError
        )
        raise ConfigurationError, "#{name} must not be empty" if text.empty?

        text
      end

      # sensitivity <= caller, expressed as the IN-list of allowed levels.
      def sensitivity_at_most(caller_sensitivity)
        SENSITIVITY_ORDER.take(SENSITIVITY_ORDER.index(caller_sensitivity) + 1)
      end

      def sensitivity_placeholders(allowed)
        Array.new(allowed.length, "?").join(", ")
      end

      # Exact/prefix matching on the indexed searchable columns only: a term
      # prefix-matches `statement_search` at a WORD BOUNDARY (`term%` at the
      # start or after a space), and prefix-matches `layer`/`class` the same
      # way; a layer/class filter is an exact equality. No full-statement
      # substring, no semantic/vector search (probe P11-09 honest-searchable
      # claim). Term values are escaped so LIKE metacharacters in a term are
      # literal.
      def match_clause(terms, layer, klass)
        clauses = []
        binds = []
        terms.each do |term|
          clauses << "(i.statement_search LIKE ? ESCAPE '\\' OR " \
                      "i.statement_search LIKE ? ESCAPE '\\' OR " \
                      "i.layer LIKE ? ESCAPE '\\' OR " \
                      "i.class LIKE ? ESCAPE '\\')"
          pattern = "#{escape_like(term)}%"
          word_pattern = "% #{pattern}"
          binds << pattern
          binds << word_pattern
          binds << pattern
          binds << pattern
        end
        if layer
          clauses << "i.layer = ?"
          binds << layer
        end
        if klass
          clauses << "i.class = ?"
          binds << klass
        end
        return ["", []] if clauses.empty?

        ["AND #{clauses.join(" AND ")}", binds]
      end

      def escape_like(term)
        term.gsub(/[\\%_]/) { |char| "\\#{char}" }
      end

      def validate_limit(value)
        return value if value.is_a?(Integer) && value.between?(1, MAX_LIMIT)

        raise ConfigurationError, "memory search limit must be between 1 and #{MAX_LIMIT}"
      end
    end
  end
end
