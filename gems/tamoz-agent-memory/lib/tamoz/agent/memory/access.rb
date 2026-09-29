# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # One owner's memory in one workspace: everything a session, the CLI, or an operator
      # does with memory. Callers name an owner and a workspace; scopes, the store layout, and
      # what is visible to whom are decided here and nowhere else.
      class Access
        LAYERS = %w[knowledge experience].freeze
        CONSOLIDATION_SESSION = 'consolidation'

        attr_reader :owner, :project

        def initialize(engine, owner:, workspace:)
          @engine = engine
          @owner = owner
          @project = Surface.project_scope(workspace)
          freeze
        end

        def caller = @engine.caller(user: owner, project:)

        def brief(task) = @engine.retrieval.brief(caller:, task:)

        def recall(query, layer: nil, limit: nil)
          records = @engine.retrieval.recall(caller:, query: { terms: [query.to_s], layer: }.compact).records
          limit ? records.first(limit) : records
        end

        # Every eligible record in scope, optionally narrowed by a query; no token budget.
        def list(query = nil)
          terms = query.to_s.strip.empty? ? [] : [query.to_s]
          rows = @engine.repository.search(caller:, query: { terms: }).candidates
          rows.filter_map { |row| read(row.fetch('layer'), row.fetch('memory_id')) }
        end

        # A record by id, only while it is eligible, unexpired, not sensitive, and in scope.
        def find(memory_id)
          LAYERS.lazy.filter_map { |layer| read(layer, memory_id.to_s) }.find { |record| visible?(record) }
        end

        def remember(quote:, user_messages:, session:, key: nil, scope: :project)
          @engine.knowledge.remember(quote:, user_messages:, owner:, project:, session:, key:, scope:)
        end

        def forget(target:, quote:, user_messages:)
          @engine.knowledge.forget(target:, quote:, user_messages:, owner:, project:)
        end

        # The operator's delete: no quote needed, but only inside this scope. nil when not found.
        def delete(memory_id)
          record = find(memory_id)
          record && @engine.lifecycle.delete(memory_id: record.memory_id, actor: owner, reason: 'operator forget')
        end

        # What a finished turn did, admitted as Experience; expired records are swept afterwards.
        def record_experience(session:, task:, plan_digest:, statement:, outcome:)
          result = @engine.admission.admit_episode(
            episode: { session_id: session, task:, plan_digest:, statement:, sensitivity: :internal,
                       completed_at: @engine.clock.call.to_i, scopes: scopes(session),
                       observed_outcome: { 'outcome' => outcome } },
            owner:
          )
          @engine.lifecycle.sweep
          result
        end

        # W3: groups of related Experience from different sessions become Knowledge through the
        # gated, journaled consolidation. A group already consumed is reported as skipped.
        def consolidate(model:, context:, limit:)
          ExperienceGroups.for(@engine, caller:, limit:).map do |group|
            consolidate_group(group, model, context)
          end
        end

        private

        def consolidate_group(group, model, context)
          sources = group.map(&:memory_id)
          scopes = scopes(CONSOLIDATION_SESSION)
          candidate = @engine.consolidation.candidate_from(experiences: group, owner:, scopes:)
          result = @engine.consolidation.consolidate(candidates: [candidate], model:, owner:, scopes:, context:)
          { 'sources' => sources, 'knowledge' => result.record.memory_id }
        rescue MemoryConsolidationError => e
          { 'sources' => sources, 'skipped' => e.message }
        end

        def scopes(session)
          { 'tenant' => @engine.tenant, 'user' => owner, 'project' => project,
            'session' => session }
        end

        def read(layer, memory_id)
          value = @engine.repository.fetch(@engine.namespace, layer, memory_id)&.fetch(:entry)&.value
          value if value.is_a?(MemoryRecord)
        end

        def visible?(record)
          record.eligible? && !record.sensitive? && record.owner == owner &&
            [project, '*'].include?(record.scopes['project']) &&
            (record.valid_until.nil? || record.valid_until.to_i > @engine.clock.call.to_i)
        end
      end
    end
  end
end
