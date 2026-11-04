# frozen_string_literal: true

module Tamoz
  # SQLite checkpoint collaborators keep the persistence boundary explicit.
  module SQLite
    # Derives effect safety counters from durable journal evidence.
    # :reek:FeatureEnvy :reek:TooManyStatements
    # The row mapping is intentionally adjacent to the audit projection so the
    # evidence fields and their published names cannot drift apart.
    class EffectCensus
      SELECT_SQL = <<~SQL
        SELECT e.effect_key, e.thread_id, e.operation, e.safety, e.status,
               e.requires_reconciliation,
               (SELECT COUNT(*) FROM tamoz_effect_attempts a
                 WHERE a.effect_key = e.effect_key AND a.status = 'succeeded'),
               (SELECT COUNT(*) FROM tamoz_effect_attempts a
                 WHERE a.effect_key = e.effect_key
                   AND a.attempt_number > (
                     SELECT MIN(u.attempt_number) FROM tamoz_effect_attempts u
                      WHERE u.effect_key = e.effect_key AND u.status = 'unknown'
                   )),
               e.request_id
        FROM tamoz_effects AS e
        ORDER BY e.created_at_ms ASC, e.effect_key ASC
        LIMIT ?
      SQL

      def initialize(adapter:)
        @adapter = adapter
        freeze
      end

      def census(limit: 10_000)
        bounded = Integer(limit)
        raise ConfigurationError, 'limit must be positive' unless bounded.positive?

        rows = @adapter.__send__(:read, operation: 'effect.census') do |tx|
          tx.rows('effect.census.select', SELECT_SQL, [bounded])
        end
        rows.map { |row| census_entry(row) }.freeze
      end

      private

      def census_entry(row)
        {
          effect_key: row.fetch(0),
          thread_id: row.fetch(1),
          operation: row.fetch(2),
          safety: row.fetch(3).to_sym,
          status: row.fetch(4).to_sym,
          requires_reconciliation: row.fetch(5) == 1,
          succeeded_attempts: row.fetch(6),
          attempts_after_unknown: row.fetch(7).to_i,
          request_id: row.fetch(8)
        }.freeze
      end
    end
    private_constant :EffectCensus
  end
end
