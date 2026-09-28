# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # Candidate groups for W3 consolidation: each active Experience with up to three
      # related episodes from other sessions. Episodes share their labels (Task, Outcome,
      # Files), so relatedness is judged on the task line alone.
      module ExperienceGroups
        MAX_RELATED = 3

        module_function

        def for(engine, caller:, limit:)
          experiences = active(engine, caller)
          groups = experiences.filter_map { |record| group_ids(engine, caller, record) }.uniq.first(limit)
          groups.map { |ids| experiences.select { |record| ids.include?(record.memory_id) } }
        end

        def group_ids(engine, caller, record)
          related = engine.retrieval.recall(caller:, query: { terms: [task_line(record)], layer: :experience }).records
          others = related.reject { |other| other.scopes['session'] == record.scopes['session'] }
          ids = ([record] + others.first(MAX_RELATED)).map(&:memory_id)
          ids.sort if ids.length >= 2
        end

        def active(engine, caller)
          rows = engine.repository.search(caller:, query: { terms: [], layer: 'experience' }).candidates
          rows.filter_map { |row| engine.store.get(engine.namespace, "experience/#{row.fetch('memory_id')}")&.value }
        end

        def task_line(record) = record.statement[/\ATask: (.*?)(?: \| |\z)/, 1] || record.statement
      end
    end
  end
end
