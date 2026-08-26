# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # P11-ED: the production-memory adapter for the DR-3 treatment harness.
      # The existing per-cell `MemoryStore` (JSON index/vault records) measures
      # injection correctness against a lightweight store; this adapter
      # drives the SAME harness cells through the REAL production memory stack
      # — `Tamoz::SQLite::MemoryStore` + the Store + `Memory::Engine`'s
      # SQL-filtered retrieval (authorization before ranking, invariant 30) —
      # behind the identical `MemoryStore` interface, so
      # `MemoryRetrieval`/`MemoryEnvelope`/`MemoryCell` work unchanged.
      #
      # Per-cell isolation (C4/E7) is preserved: one real SQLite store file per
      # (case, treatment) cell, seeded from the pinned corpus records with a
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
      # Seed contract (the corpus schema pins `epoch`/`classification`/
      # `match_keys`/`content`): the searchable STATEMENT is derived from the
      # record's `match_keys` vocabulary (the real search ANDs query terms at
      # word boundaries, so the corpus vocabulary is the query the prompt
      # warrants — see `scan`), while the rendered CONTENT stays the record's
      # structured hash. `absorb` refuses prompt-sourced content structurally,
      # exactly like the JSON store, so the seeded store never mutates during a
      # CI run.
      class MemoryRepositoryAdapter
        attr_reader :path, :decrypt_reads, :absorb_refusals, :absorbed_count,
                    :seed_digest, :engine, :adapter

        def initialize(path, config:, clock: nil)
          @path = File.expand_path(path)
          @config = DeepFreeze.call(config)
          @clock = clock || -> { Time.at(seed_epoch) }
          @decrypt_reads = 0
          @absorb_refusals = 0
          @absorbed_count = 0
          @seed_digest = nil
          @seed_records = {}
        end

        def self.seed(path, seed_records, config:)
          store = new(path, config:)
          store.seed(seed_records)
          store
        end

        # Deterministic seed: a fresh real store, one active MemoryRecord per
        # supplied record through the repository append contract.
        def seed(seed_records)
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
            tenant: tenant, adapter: @adapter, clock: @clock
          )
          seed_records.each do |seed_record|
            memory_id = seed_record.fetch("memory_id")
            @seed_records[memory_id] = seed_record
            append_record(seed_record)
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
        # record's `match_keys`), and the real SQL search runs those terms
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
          seed_record = seed_record(memory_id)
          entry = {
            "memory_id" => seed_record.fetch("memory_id"),
            "record_version" => seed_record.fetch("record_version"),
            "epoch" => seed_record.fetch("epoch"),
            "classification" => seed_record.fetch("classification"),
            "match_keys" => seed_record.fetch("match_keys")
          }
          if restricted?(seed_record)
            entry["vaulted"] = true
          else
            entry["content"] = seed_record.fetch("content")
          end
          DeepFreeze.call(entry)
        end

        # Full record. Reading a RESTRICTED record's body decrypts it through
        # the real store (instrumented via the counting protection codec).
        def record(memory_id)
          seed_record = seed_record(memory_id)
          entry = metadata(memory_id)
          return entry if entry["classification"] != restricted_classification

          # Authorized read of the restricted body: the real store materializes
          # + decrypts (the counting protection records it).
          @engine.store.get(@engine.namespace, "#{layer(seed_record)}/#{memory_id}")
          @decrypt_reads += 1
          DeepFreeze.call(entry.merge("content" => seed_record.fetch("content")))
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

        def restricted_classification
          @config.fetch("restricted_classification")
        end

        def tenant
          @config.fetch("tenant")
        end

        def user
          @config.fetch("user")
        end

        def project
          @config.fetch("project")
        end

        def seed_epoch
          @config.fetch("seed_epoch")
        end

        def compatibility
          @config.fetch("compatibility")
        end

        def klass_by_layer
          @config.fetch("klass_by_layer").transform_keys(&:to_sym).transform_values(&:to_sym)
        end

        def epistemic_kind_by_layer
          @config.fetch("epistemic_kind_by_layer").transform_keys(&:to_sym).transform_values(&:to_sym)
        end

        def seed_record(memory_id)
          @seed_records.fetch(memory_id) do
            raise ExecutionError, "memory store has no record #{memory_id}"
          end
        end

        def restricted?(seed_record)
          seed_record.fetch("classification") == restricted_classification
        end

        def layer(seed_record)
          seed_record.fetch("epoch")
        end

        # The seeded vocabulary: every record's match_keys, deduplicated and
        # lowercased. The corpus guarantees every record's searchable
        # statement contains this vocabulary, so the AND-ed terms match
        # deterministically.
        def vocabulary
          @vocabulary ||= @seed_records.values
                                   .flat_map { |seed_record| seed_record.fetch("match_keys") }
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
            tenant: tenant,
            user: user,
            project: project,
            sensitivity: :public,
            compatibility_graph: compatibility.fetch("graph_version"),
            compatibility_behavior: compatibility.fetch("behavior_version")
          }
        end

        def append_record(seed_record)
          record = build_memory_record(seed_record)
          @engine.repository.append(
            record:,
            index: @engine.index_for(record),
            expected_version: nil,
            sensitive: record.sensitive?
          )
        end

        def build_memory_record(seed_record)
          layer_sym = layer(seed_record).to_sym
          sensitive = restricted?(seed_record)
          statement = build_statement(seed_record)
          Tamoz::Agent::Memory::MemoryRecord.new(
            memory_id: seed_record.fetch("memory_id"),
            record_version: seed_record.fetch("record_version", 1),
            layer: layer_sym,
            klass: klass_by_layer.fetch(layer_sym),
            state: :active,
            statement:,
            epistemic_kind: epistemic_kind_by_layer.fetch(layer_sym),
            source_refs: [{
              "identity" => "eval-seed",
              "digest" => seed_digest_for(seed_record),
              "observed_at" => seed_epoch
            }],
            owner: user,
            actor: user,
            scopes: {
              "tenant" => tenant, "user" => user, "project" => project,
              "session" => seed_record.fetch("memory_id")
            },
            sensitivity: sensitive ? :sensitive : :public,
            disclosure_policy: "default",
            confidence: 0.95,
            confidence_method: "eval_seed",
            valid_from: seed_epoch,
            created_by: {"surface" => "eval_seed"},
            compatibility: compatibility,
            transition: {
              "actor" => user, "authority" => "eval_seed",
              "reason" => "deterministic seed", "policy_version" => "1",
              "timestamp" => seed_epoch * 1000, "trace_id" => "eval-seed"
            },
            created_at_ms: seed_epoch * 1000
          )
        end

        # The searchable statement: the record vocabulary + the rendered
        # content, so every real-search term the corpus warrants matches the
        # indexed statement while the rendered content stays the record hash.
        def build_statement(seed_record)
          prefix = seed_record.fetch("match_keys").join(" ")
          "#{prefix}: #{CanonicalJSON.dump(seed_record.fetch("content"))}"
        end

        def seed_digest_for(seed_record)
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(seed_record))}"
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
