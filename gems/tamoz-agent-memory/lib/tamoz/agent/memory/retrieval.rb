# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §4 P11-B: retrieval authorizes BEFORE ranking. The repository runs
      # the scope ∩ layer/class ∩ state ∩ sensitivity ∩ validity ∩
      # compatibility filters in SQL; this layer RANKS the already-authorized
      # candidates, applies the bounded token budget, and emits the trace marks.
      #
      # Ranking: full-text relevance (bm25) + freshness + base quality −
      # contradiction − correction − stale penalties, recomputed from immutable
      # fields at read time (never double-decay).
      #
      # A recalled record is marked in the trace and carries a `recalled` flag
      # so it can never be admitted as new Experience evidence (anti
      # self-ingestion loop).
      class Retrieval
        RECALL_EVENT = :memory_recalled
        DROPPED_EVENT = :memory_dropped

        MAX_QUERY_TERMS = 64
        RELEVANCE_WEIGHT = 2.0
        BRIEF_CLASSES = %w[preference constraint].freeze
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

        # Explicit retrieval (`automatic: false`): any eligible layer, ranked,
        # truncated by rank at the token budget. `automatic: true` is the
        # injection policy: Knowledge only, never sensitive, at most
        # max_injected_knowledge, lowest-ranked dropped and traced.
        def recall(caller:, query:, trace: nil, automatic: false)
          query = query.merge(layer: :knowledge) if automatic
          result = @engine.repository.search(caller:, query: normalize_query(query),
                                             limit: @limits.fetch(:max_lexical_hits))
          # Candidate retrieval happens ONLY after the SQL authorization
          # filter. Automatic injection excludes sensitive rows BEFORE
          # materialization so a record that can never be injected is never
          # decrypted.
          rows = result.candidates
          rows = rows.reject { |row| row.fetch("sensitivity") == "sensitive" } if automatic

          ranked = rank(materialize(rows), relevance_of(rows))
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

        # The Knowledge brief injected at a turn's start: the active preferences
        # and constraints in scope (newest first) and the Knowledge relevant to
        # the task. Never Experience, never sensitive. Bounded by
        # max_injected_knowledge and retrieval_token_budget; every record that
        # does not fit is traced as dropped.
        def brief(caller:, task:, trace: nil)
          profile = BRIEF_CLASSES.flat_map { |klass| knowledge_rows(caller, terms: [], klass:) }
          relevant = knowledge_rows(caller, terms: [task])
          profile_records = materialize(profile).sort_by { |record| -record.transition.fetch("timestamp", 0).to_i }
          ranked = rank(materialize(relevant), relevance_of(relevant))
          # Half the slots go to the profile first, so a long profile never
          # crowds out the Knowledge this task needs; leftovers compete after.
          slots = @limits.fetch(:max_injected_knowledge) / 2
          ordered = (profile_records.first(slots) + ranked + profile_records.drop(slots)).uniq(&:memory_id)
          selected, dropped = fit_brief(ordered)
          record_drops(dropped, trace:, automatic: true)
          records = selected.map { |record| mark_recalled(record) }
          records.each { |record| emit_recall(trace, record) } if trace
          RecallResult.new(records:, dropped_ids: dropped.map(&:memory_id))
        end

        private

        def knowledge_rows(caller, terms:, klass: nil)
          query = normalize_query(terms:, layer: :knowledge, class: klass)
          @engine.repository.search(caller:, query:, limit: @limits.fetch(:max_lexical_hits))
                 .candidates.reject { |row| row.fetch("sensitivity") == "sensitive" }
        end

        def fit_brief(records)
          cap = @limits.fetch(:max_injected_knowledge)
          budget = @limits.fetch(:retrieval_token_budget)
          used = 0
          selected = []
          dropped = []
          records.each do |record|
            tokens = token_estimate(record)
            if selected.length < cap && used + tokens <= budget
              selected << record
              used += tokens
            else
              dropped << record
            end
          end
          [selected, dropped]
        end

        def relevance_of(rows)
          rows.to_h { |row| [row.fetch("memory_id"), row.fetch("relevance", 0.0).to_f] }
        end

        def normalize_query(query)
          terms = Array(query[:terms]).flat_map { |term| term.to_s.split(/[^[:alnum:]]+/) }.reject(&:empty?)
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
        # records: relevance (bm25, scaled to the best candidate) + freshness +
        # base quality − contradiction − correction − stale penalties.
        def rank(records, relevance)
          top = relevance.values.max.to_f
          scale = top.positive? ? 1.0 / top : 0.0
          records.sort_by { |record| -rank_score(record, relevance.fetch(record.memory_id, 0.0) * scale) }
        end

        def rank_score(record, relevance)
          conflict_penalty = record.contradiction_set_id ? CONTRADICTION_PENALTY : 0.0
          correction_penalty = record.use_counts.fetch("corrected", 0).to_f * CORRECTION_PENALTY
          score = (RELEVANCE_WEIGHT * relevance) + freshness_score(record) + record.base_quality.to_f -
                  conflict_penalty - stale_penalty(record) - correction_penalty
          [score, 0.0].max
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
