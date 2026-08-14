# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/situation_recall"

module Tamoz
  module Agent
    module Memory
      # Materializes only authorized, observed Experience records and projects
      # them into the storage-agnostic stream recall contract.
      class SituationRecaller
        MAX_RECORDS = 64
        MAX_BYTES = 32 * 1024
        CALLER = {
          user: "stream",
          project: "stream",
          sensitivity: :internal,
          compatibility: {graph_version: "1", behavior_version: BEHAVIOR_VERSION}
        }.freeze

        def initialize(engine:, max_records: MAX_RECORDS, max_bytes: MAX_BYTES)
          @engine = engine
          @max_records = positive_limit(max_records, MAX_RECORDS, "record limit")
          @max_bytes = positive_limit(max_bytes, MAX_BYTES, "byte limit")
          freeze
        end

        def recall(caller:, snapshot:, query: {terms: []}, limit: @max_records)
          validate_caller!(caller)
          validate_snapshot!(snapshot)
          normalized_limit = positive_limit(limit, @max_records, "recall limit")
          search = @engine.repository.search(
            caller: situation_caller(caller, snapshot),
            query: normalized_query(query),
            limit: [normalized_limit * 8, 512].min
          )
          build_result(search, snapshot, normalized_limit)
        end

        private

        def validate_caller!(caller)
          actual = caller.transform_keys(&:to_sym)
          expected = @engine.caller(**CALLER)
          expected.each do |key, value|
            next if actual.fetch(key) == value

            raise MemoryPolicyError, "situation recall caller is not trusted"
          end
          unless actual.fetch(:tenant) == @engine.tenant
            raise MemoryPolicyError, "situation recall caller tenant is not configured"
          end
        rescue KeyError
          raise MemoryPolicyError, "situation recall caller is incomplete"
        end

        def validate_snapshot!(snapshot)
          unless snapshot.is_a?(Hash) && snapshot.fetch("tenant_id") == @engine.tenant
            raise MemoryPolicyError, "situation recall snapshot tenant is not configured"
          end
          entity = snapshot.fetch("entity")
          require_text(snapshot, "situation_type")
          require_text(entity, "type")
          require_text(entity, "id")
        rescue KeyError, TypeError
          raise MemoryPolicyError, "situation recall snapshot identity is incomplete"
        end

        def situation_caller(caller, snapshot)
          entity = snapshot.fetch("entity")
          caller.merge(
            situation_type: snapshot.fetch("situation_type"),
            entity_type: entity.fetch("type"),
            entity_id: entity.fetch("id")
          )
        end

        def normalized_query(query)
          unless query.is_a?(Hash) && Array(query.fetch(:terms, [])).empty?
            raise MemoryPolicyError, "situation recall accepts an empty lexical term set"
          end

          {terms: [], layer: "experience", class: "episode"}
        end

        def build_result(search, snapshot, limit)
          current_entity_id = snapshot.fetch("entity").fetch("id")
          dropped = []
          projections = []
          used_bytes = 0
          truncated = false
          search.candidates.each do |row|
            next if row.fetch("scopes_entity_id") == current_entity_id

            record = materialize(row)
            unless eligible_observed_episode?(record)
              dropped << drop("not_observed_verified_experience")
              next
            end
            projection = projection(record)
            bytes = Tamoz::Core.jcs(projection.to_h).bytesize
            if projections.length >= limit || used_bytes + bytes > @max_bytes
              dropped << drop("recall_bound")
              truncated = true
              next
            end

            projections << projection
            used_bytes += bytes
          end
          Tamoz::Stream::SituationRecall::Result.new(
            records: projections,
            record_digests: projections.map(&:digest),
            restricted: restricted_metadata(search),
            dropped:,
            truncated:
          )
        end

        def materialize(row)
          entry = @engine.store.get(
            @engine.namespace, "#{row.fetch("layer")}/#{row.fetch("memory_id")}"
          )
          entry&.value
        end

        def eligible_observed_episode?(record)
          record.is_a?(MemoryRecord) && record.layer == :experience &&
            record.klass == :episode && record.eligible? &&
            record.epistemic_kind == :observed && episode_provenance(record) &&
            verified_provenance(record)
        end

        def episode_provenance(record)
          record.source_refs.find do |ref|
            ref["identity"].to_s.start_with?("episode:") &&
              !ref["identity"].to_s.delete_prefix("episode:").empty?
          end
        end

        def verified_provenance(record)
          record.source_refs.any? do |ref|
            ref["identity"].to_s.start_with?("outcome:") &&
              %w[command_id decision_id source_authority reconciliation_version].all? do |key|
                ref.key?(key) && !ref.fetch(key).to_s.empty?
              end
          end
        end

        def projection(record)
          episode = episode_provenance(record)
          outcome = record.source_refs.find do |ref|
            ref["identity"].to_s.start_with?("outcome:")
          end
          scopes = record.scopes.slice(
            "tenant", "situation_type", "entity_type", "entity_id"
          )
          provenance = {
            "episode_id" => episode.fetch("identity").delete_prefix("episode:"),
            "decision_id" => outcome.fetch("decision_id"),
            "command_id" => outcome.fetch("command_id"),
            "outcome_id" => outcome.fetch("identity").delete_prefix("outcome:")
          }
          Tamoz::Stream::SituationRecall::Projection.new(
            statement: record.statement,
            scopes:,
            provenance:,
            digest: record.digest
          )
        end

        def restricted_metadata(search)
          return [] if search.matched_restricted.empty?

          [{"reason" => "sensitivity", "count" => search.matched_restricted.length}]
        end

        def drop(reason)
          {"reason" => reason}
        end

        def require_text(hash, key)
          value = hash.fetch(key)
          raise MemoryPolicyError if !value.is_a?(String) || value.empty?
        end

        def positive_limit(value, maximum, name)
          unless value.is_a?(Integer) && value.positive? && value <= maximum
            raise MemoryPolicyError, "#{name} must be between 1 and #{maximum}"
          end

          value
        end
      end
    end
  end
end
