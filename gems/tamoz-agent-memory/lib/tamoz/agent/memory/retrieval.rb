# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §4 P11-B: retrieval authorizes BEFORE ranking. The repository runs
      # the scope ∩ layer/class ∩ state ∩ sensitivity ∩ validity ∩
      # compatibility filters in SQL; this layer RANKS the already-authorized
      # candidates, applies the bounded token budget, and emits the trace marks.
      #
      # Ranking (plan §4): relevance + source quality + freshness + successful
      # use − contradiction − correction − stale penalties, recomputed from
      # immutable `base_quality` and `last_evaluated_at` (never double-decay).
      #
      # A recalled record is marked in the trace and carries a `recalled` flag
      # so it can never be admitted as new Experience evidence (anti
      # self-ingestion loop).
      class Retrieval
        RECALL_EVENT = :memory_recalled
        DROPPED_EVENT = :memory_dropped

        MAX_QUERY_TERMS = 32
        FULL_QUALITY_REFS = 4.0
        FRESHNESS_DECAY_HOURS = 720.0
        STALE_WINDOW_HOURS = 24
        STALE_PENALTY = 0.4
        CONTRADICTION_PENALTY = 0.2
        CORRECTION_PENALTY = 0.1
        MS_PER_HOUR = 3_600_000.0

        RecallResult = Data.define(:records, :matched_restricted_ids, :dropped_ids, :truncated) do
          def initialize(records: [], matched_restricted_ids: [], dropped_ids: [], truncated: false)
            super(
              records: records.freeze,
              matched_restricted_ids: matched_restricted_ids.freeze,
              dropped_ids: dropped_ids.freeze,
              truncated:
            )
          end

          def recalled_ids
            records.map(&:memory_id)
          end
        end

        def initialize(engine)
          @engine = engine
          @limits = engine.limits
        end

        # The one retrieval entry point. `automatic: true` is the injection
        # policy (Knowledge/Wisdom only, never sensitive, at most
        # max_injected_knowledge, budget-dropped lowest-first); `automatic:
        # false` is explicit retrieval (any eligible layer, truncate by rank).
        def recall(caller:, query:, trace: nil, automatic: false)
          limit = @limits.fetch(:max_lexical_hits)
          result = @engine.repository.search(caller:, query: normalize_query(query), limit:)
          # Candidate retrieval happens ONLY after the SQL authorization
          # filter: the rows below are authorized candidates. Automatic
          # injection excludes sensitive rows BEFORE materialization so a
          # record that can never be injected is never decrypted.
          rows = result.candidates
          rows = rows.reject { |row| row.fetch("sensitivity") == "sensitive" } if automatic
          fetched = materialize(rows)

          ranked = rank(fetched)
          budgeted, dropped, truncated = apply_budget(ranked, automatic:)
          record_drops(dropped, trace:, automatic:)
          records = budgeted.map { |record| mark_recalled(record) }

          records.each do |record|
            emit_recall(trace, record) if trace
          end

          RecallResult.new(
            records:,
            matched_restricted_ids: result.matched_restricted.map { |row| row.fetch("memory_id") },
            dropped_ids: dropped.map(&:memory_id),
            truncated:
          )
        end

        private

        def normalize_query(query)
          terms = Array(query[:terms]).map(&:to_s).flat_map { |term| term.split(/[^A-Za-z0-9]+/) }.reject(&:empty?)
          {
            terms: terms.first(MAX_QUERY_TERMS),
            layer: query[:layer] && query[:layer].to_s,
            class: query[:class] && query[:class].to_s
          }
        end

        def materialize(rows)
          rows.filter_map do |row|
            entry = @engine.store.get(@engine.namespace, "#{row.fetch("layer")}/#{row.fetch("memory_id")}")
            next nil unless entry && entry.value.is_a?(MemoryRecord)

            entry.value
          end
        end

        # Deterministic ranking over the already-authorized, materialized
        # records: relevance + source quality + freshness + successful use −
        # contradiction − correction − stale penalties, recomputed from
        # immutable base_quality / last_evaluated_at (never double-decay).
        def rank(records)
          records.map { |record| [record, rank_score(record)] }
                 .sort_by { |_record, score| -score }
                 .map(&:first)
        end

        def rank_score(record)
          base = record.base_quality.to_f
          source_quality = [record.source_refs.length.to_f / FULL_QUALITY_REFS, 1.0].min
          freshness = freshness_score(record)
          conflict_penalty = record.contradiction_set_id ? CONTRADICTION_PENALTY : 0.0
          stale_penalty = stale_penalty(record)
          correction_penalty = record.use_counts.fetch("corrected", 0).to_f * CORRECTION_PENALTY
          [base + source_quality + freshness - conflict_penalty - stale_penalty - correction_penalty, 0.0].max
        end

        def freshness_score(record)
          valid_from = record.valid_from
          return 0.0 unless valid_from

          age_hours = (@engine.now_ms - valid_from.to_i * 1000) / MS_PER_HOUR
          [1.0 - (age_hours / FRESHNESS_DECAY_HOURS), 0.0].max
        end

        def stale_penalty(record)
          valid_until = record.valid_until
          return 0.0 unless valid_until

          remaining_hours = (valid_until.to_i * 1000 - @engine.now_ms) / MS_PER_HOUR
          remaining_hours < STALE_WINDOW_HOURS ? STALE_PENALTY : 0.0
        end

        def apply_budget(records, automatic:)
          budget = @limits.fetch(:retrieval_token_budget)
          cap = automatic ? @limits.fetch(:max_injected_knowledge) : records.length
          selected = []
          dropped = []
          used = 0
          truncated = false
          records.each do |record|
            tokens = token_estimate(record)
            break if selected.length >= cap

            if used + tokens > budget
              if automatic
                # Drop the lowest-ranked admissible record and record the drop.
                dropped << selected.pop if selected.any?
                used = selected.sum { |entry| token_estimate(entry) }
              else
                truncated = true
                break
              end
            end
            next if selected.include?(record)

            selected << record
            used += tokens
          end
          [selected, dropped, truncated]
        end

        def token_estimate(record)
          [(record.statement.bytesize / 4.0).ceil, 1].max
        end

        def mark_recalled(record)
          transition = (record.transition || {}).merge("recalled" => true)
          record.with(transition:)
        end

        def emit_recall(trace, record)
          trace << Tamoz::Agent::Event.new(
            type: RECALL_EVENT,
            data: Tamoz::Core.deep_freeze(
              "memory_id" => record.memory_id,
              "record_version" => record.record_version,
              "layer" => record.layer.to_s,
              "classification" => record.sensitive? ? "restricted" : "public",
              "authorized" => true
            )
          )
        end

        def record_drops(dropped, trace:, automatic:)
          return unless automatic && trace

          dropped.each do |record|
            trace << Tamoz::Agent::Event.new(
              type: DROPPED_EVENT,
              data: Tamoz::Core.deep_freeze(
                "memory_id" => record.memory_id,
                "reason" => "automatic_injection_budget"
              )
            )
          end
        end
      end
    end
  end
end
