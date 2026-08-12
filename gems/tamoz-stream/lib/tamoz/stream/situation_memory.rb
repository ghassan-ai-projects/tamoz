# frozen_string_literal: true

module Tamoz
  module Stream
    # T5.4 (PLAN_TAMOZ_STREAM_BUILD T5.4): situation-scoped retrieval over
    # the T0.3 schema. The relatedness authority default is "same tenant AND
    # same entity type" (plan §5, adopted for T0.3): the repository's
    # authorize-before-rank boundary binds the entity type, so a
    # situation-scoped caller retrieves only rows of the same entity type
    # within its tenant — a second occurrence on a RELATED entity retrieves
    # the first occurrence's Experience, and an entity outside the boundary
    # (different tenant or entity type) retrieves nothing.
    #
    # This layer names the situation dimension from the VERIFIED snapshot and
    # narrows retrieval to related entities (a different entity id) when
    # asked. Narrowing never widens an authorization boundary — the boundary
    # itself lives in the repository's SQL, not here.
    module SituationMemory
      module_function

      # The entity's own memory plus same-type related memory (the default
      # boundary). `caller` is the base caller hash; the situation identity
      # comes from the verified snapshot, never from unverified input.
      def retrieve(repository:, caller:, snapshot:, query: {terms: []}, limit: 20)
        repository.search(
          caller: situation_caller(caller, snapshot),
          query: query,
          limit: limit
        )
      end

      # Related-entity retrieval only: same tenant AND same entity type, a
      # DIFFERENT entity id. The candidates are the boundary's result filtered
      # to related entities — the entity id filter narrows, it cannot widen.
      def related(repository:, caller:, snapshot:, query: {terms: []}, limit: 20)
        entity_id = snapshot.fetch("entity").fetch("id")
        result = retrieve(
          repository:, caller:, snapshot:, query:, limit: limit * 4
        )
        candidates = result.candidates.select do |row|
          row.fetch("scopes_entity_id", nil) != entity_id
        end
        {
          candidates: candidates.first(limit),
          matched_restricted: result.matched_restricted
        }
      end

      def situation_caller(caller, snapshot)
        entity = snapshot.fetch("entity")
        caller.merge(
          situation_type: snapshot.fetch("situation_type"),
          entity_type: entity.fetch("type"),
          entity_id: entity.fetch("id")
        )
      end
    end
  end
end
