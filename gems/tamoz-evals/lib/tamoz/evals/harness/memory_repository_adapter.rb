# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # P11-ED: the production-memory adapter for the DR-3 treatment harness.
      # The existing per-cell `MemoryStore` (JSON index/vault fixtures) measures
      # injection correctness against a lightweight fixture store; this adapter
      # drives the SAME harness cells through the REAL production memory stack
      # — `Tamoz::SQLite::MemoryStore` + the Store + `Memory::Engine`'s
      # SQL-filtered retrieval (authorization before ranking, invariant 30) —
      # behind the identical `MemoryStore` interface, so
      # `MemoryRetrieval`/`MemoryEnvelope`/`MemoryCell` work unchanged.
      #
      # Per-cell isolation (C4/E7) is preserved: one real SQLite store file per
      # (case, treatment) cell, seeded from the pinned corpus fixtures with a
      # deterministic clock, and a content digest over the store rows that is
      # stable across runs (E5) — wall-clock timestamps are excluded, payload
      # digests and index rows are not.
      #
      # The decryption boundary (P11-07/P11-25) is instrumented through a
      # counting protection codec: a scan that matches a sensitive record
      # reports it via `matched_restricted_ids` and NEVER decrypts it
      # (`decrypt_reads` stays zero); only an authorized read of a restricted
      # record's body increments the counter.
      #
      # Fixture contract (the corpus schema pins `epoch`/`classification`/
      # `match_keys`/`content`): the searchable STATEMENT is derived from the
      # fixture's `match_keys` vocabulary (the real search ANDs query terms at
      # word boundaries, so the corpus vocabulary is the query the prompt
      # warrants — see `scan`), while the rendered CONTENT stays the fixture's
      # structured hash. `absorb` refuses prompt-sourced content structurally,
      # exactly like the JSON store, so the seeded store never mutates during a
      # CI run.
      class MemoryRepositoryAdapter
        RESTRICTED = "restricted"
        TENANT = "eval"
        USER = "alice"
        PROJECT = "proj"
        # Deterministic seed epoch: every seeded record's timestamps are pinned
        # so two seeds of the same fixtures are byte-identical (E5/E7).
        SEED_EPOCH = 1_700_000_000
        COMPATIBILITY = {
          "graph_version" => "1",
          "behavior_version" => "tamoz.agent.session/1"
        }.freeze
        KLASS_BY_LAYER = {experience: :procedure, knowledge: :procedure, wisdom: :strategy}.freeze
        EPISTEMIC_KIND_BY_LAYER = {experience: :observed, knowledge: :reported, wisdom: :inferred}.freeze

        attr_reader :path, :decrypt_reads, :absorb_refusals, :absorbed_count,
                    :seed_digest, :engine, :adapter

        def initialize(path, clock: nil)
          @path = File.expand_path(path)
          @clock = clock || -> { Time.at(SEED_EPOCH) }
          @decrypt_reads = 0
          @absorb_refusals = 0
          @absorbed_count = 0
          @seed_digest = nil
          @fixtures = {}
        end

        def self.seed(path, fixtures)
          store = new(path)
          store.seed(fixtures)
          store
        end

        # Deterministic seed: a fresh real store, one active MemoryRecord per
        # fixture through the repository append contract (the same structural
        # contract admission uses; the admission SEMANTICS are covered by the
        # memory engine tests — this is fixture-pinned seeding, not admission).
        def seed(fixtures)
          require "tamoz/sqlite"
          require "tamoz/agent"

          FileUtils.mkdir_p(File.dirname(@path))
          @protection = CountingProtection.new
          @adapter = Tamoz::SQLite::Adapter.new(
            path: @path,
            store_protection: @protection,
            state_codec: Tamoz::Agent::Memory::Surface.codec,
            limits: Tamoz::SQLite::Limits.new(deletion_retention: 86_400.0)
          )
          @engine = Tamoz::Agent::Memory::Engine.new(
            tenant: TENANT, adapter: @adapter, clock: @clock
          )
          fixtures.each do |fixture|
            memory_id = fixture.fetch("memory_id")
            @fixtures[memory_id] = fixture
            append_fixture(fixture)
          end
          @seed_digest = digest
          @seed_digest
        end

        def close
          @adapter.close if @adapter && !@adapter.closed?
        end

        # Content digest over the store's memory rows + the lexical index —
        # deterministic across runs (wall-clock timestamps excluded). A foreign
        # or mutated record changes it, so `seed_intact?` detects cross-cell
        # contamination (E7) and post-run drift (E5).
        def digest
          raise ExecutionError, "memory repository adapter is not seeded" unless @engine

          body = {}
          @engine.store.open_transaction(label: "memory.adapter.digest") do |tx|
            body["store"] = tx.rows(
              "memory.adapter.digest.store",
              <<~SQL,
                SELECT h.namespace, h.key, h.current_version, h.deleted,
                       h.sensitive, v.payload_digest
                FROM tamoz_store_heads h
                JOIN tamoz_store_versions v
                  ON v.namespace = h.namespace
                 AND v.key = h.key
                 AND v.version = h.current_version
                WHERE h.namespace LIKE 'tamoz.memory.%'
                ORDER BY h.namespace, h.key
              SQL
              []
            )
            body["index"] = tx.rows(
              "memory.adapter.digest.index",
              <<~SQL,
                SELECT store_namespace, memory_id, record_version, layer, class,
                       state, scopes_tenant, scopes_user, scopes_project,
                       sensitivity, valid_until_ms, compatibility_graph,
                       compatibility_behavior, statement_search, searchable
                FROM tamoz_memory_index
                ORDER BY store_namespace, memory_id, record_version
              SQL
              []
            )
          end
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(body))}"
        end

        def seed_intact?
          @seed_digest && digest == @seed_digest
        end

        # The real retrieval decision: the prompt's words are intersected with
        # the seeded vocabulary (the corpus pins that vocabulary into every
        # fixture's `match_keys`), and the real SQL search runs those terms
        # through the production authorization filters. Sensitive records are
        # excluded from candidates BEFORE materialization (never decrypted) and
        # reported separately as `matched_restricted_ids` — the non-vacuous
        # hard-zero signal (P11-25/C8).
        def scan(query)
          terms = vocabulary_terms(query)
          recall = @engine.retrieval.recall(
            caller: retrieval_caller,
            query: {terms:},
            automatic: true
          )
          {
            "matched_ids" => recall.records.map(&:memory_id),
            "matched_restricted_ids" => recall.matched_restricted_ids
          }
        end

        # Index metadata (no bodies). Never touches a sensitive body.
        def metadata(memory_id)
          fixture = fixture(memory_id)
          entry = {
            "memory_id" => fixture.fetch("memory_id"),
            "record_version" => fixture.fetch("record_version"),
            "epoch" => fixture.fetch("epoch"),
            "classification" => fixture.fetch("classification"),
            "match_keys" => fixture.fetch("match_keys")
          }
          if restricted?(fixture)
            entry["vaulted"] = true
          else
            entry["content"] = fixture.fetch("content")
          end
          DeepFreeze.call(entry)
        end

        # Full record. Reading a RESTRICTED record's body decrypts it through
        # the real store (instrumented via the counting protection codec).
        def record(memory_id)
          fixture = fixture(memory_id)
          entry = metadata(memory_id)
          return entry if entry["classification"] != RESTRICTED

          # Authorized read of the restricted body: the real store materializes
          # + decrypts (the counting protection records it).
          @engine.store.get(@engine.namespace, "#{layer(fixture)}/#{memory_id}")
          @decrypt_reads += 1
          DeepFreeze.call(entry.merge("content" => fixture.fetch("content")))
        end

        # Admission boundary: prompt-sourced content is always refused; nothing
        # from a prompt is ever written, so the store stays seed-stable in CI
        # (the real admission semantics are covered by the memory engine tests).
        def absorb(_fields, prompt_sourced:)
          if prompt_sourced
            @absorb_refusals += 1
            return :refused
          end

          raise ExecutionError, "memory admission is a live-layer operation"
        end

        private

        def fixture(memory_id)
          @fixtures.fetch(memory_id) do
            raise ExecutionError, "memory store has no record #{memory_id}"
          end
        end

        def restricted?(fixture)
          fixture.fetch("classification") == RESTRICTED
        end

        def layer(fixture)
          fixture.fetch("epoch")
        end

        # The seeded vocabulary: every fixture's match_keys, deduplicated and
        # lowercased. The corpus guarantees every fixture's searchable
        # statement contains this vocabulary, so the AND-ed terms match
        # deterministically.
        def vocabulary
          @vocabulary ||= @fixtures.values
                                   .flat_map { |fixture| fixture.fetch("match_keys") }
                                   .map(&:downcase)
                                   .uniq
                                   .freeze
        end

        # The prompt's words that belong to the seeded vocabulary (case-
        # insensitive; the real engine's SQLite LIKE is ASCII-case-insensitive).
        # The harness envelope scans with the FULL prompt, so the query is
        # bounded to the corpus vocabulary the prompt actually warrants — a
        # deterministic, honest subset of the real retrieval path.
        def vocabulary_terms(query)
          words = query.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map(&:downcase)
          terms = words.select { |word| vocabulary.include?(word) }.uniq
          terms.empty? ? ["__no_match__"] : terms
        end

        def retrieval_caller
          {
            tenant: TENANT,
            user: USER,
            project: PROJECT,
            sensitivity: :public,
            compatibility_graph: COMPATIBILITY.fetch("graph_version"),
            compatibility_behavior: COMPATIBILITY.fetch("behavior_version")
          }
        end

        def append_fixture(fixture)
          record = build_memory_record(fixture)
          @engine.repository.append(
            record:,
            index: @engine.index_for(record),
            expected_version: nil,
            sensitive: record.sensitive?
          )
        end

        def build_memory_record(fixture)
          layer_sym = layer(fixture).to_sym
          sensitive = restricted?(fixture)
          statement = build_statement(fixture)
          Tamoz::Agent::Memory::MemoryRecord.new(
            memory_id: fixture.fetch("memory_id"),
            record_version: fixture.fetch("record_version", 1),
            layer: layer_sym,
            klass: KLASS_BY_LAYER[layer_sym],
            state: :active,
            statement:,
            epistemic_kind: EPISTEMIC_KIND_BY_LAYER[layer_sym],
            source_refs: [{
              "identity" => "eval-seed",
              "digest" => seed_digest_for(fixture),
              "observed_at" => SEED_EPOCH
            }],
            owner: USER,
            actor: USER,
            scopes: {
              "tenant" => TENANT, "user" => USER, "project" => PROJECT,
              "session" => fixture.fetch("memory_id")
            },
            sensitivity: sensitive ? :sensitive : :public,
            disclosure_policy: "default",
            confidence: 0.95,
            confidence_method: "eval_seed",
            valid_from: SEED_EPOCH,
            created_by: {"surface" => "eval_seed"},
            compatibility: COMPATIBILITY,
            transition: {
              "actor" => USER, "authority" => "eval_seed",
              "reason" => "deterministic seed", "policy_version" => "1",
              "timestamp" => SEED_EPOCH * 1000, "trace_id" => "eval-seed"
            },
            created_at_ms: SEED_EPOCH * 1000
          )
        end

        # The searchable statement: the fixture vocabulary + the rendered
        # content, so every real-search term the corpus warrants matches the
        # indexed statement while the rendered content stays the fixture hash.
        def build_statement(fixture)
          prefix = fixture.fetch("match_keys").join(" ")
          "#{prefix}: #{CanonicalJSON.dump(fixture.fetch("content"))}"
        end

        def seed_digest_for(fixture)
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(fixture))}"
        end

        # A deterministic protection codec (XOR) with a decrypt counter — the
        # decryption-boundary instrumentation target (P11-07/P11-25).
        class CountingProtection
          attr_reader :decrypts, :encrypts

          def initialize
            @decrypts = 0
            @encrypts = 0
            @byte = 0x5A
          end

          def name = "evals.memory-repository.xor"

          def encrypt(bytes, context:)
            @encrypts += 1
            bytes.b.bytes.map { |byte| byte ^ @byte }.pack("C*")
          end

          def decrypt(bytes, context:)
            @decrypts += 1
            bytes.bytes.map { |byte| byte ^ @byte }.pack("C*")
          end
        end
      end
    end
  end
end
