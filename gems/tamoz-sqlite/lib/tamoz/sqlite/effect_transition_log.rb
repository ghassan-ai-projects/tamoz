# frozen_string_literal: true

require 'json'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Appends the ordered audit transition for an effect inside its transaction.
    module EffectTransitionLog
      module_function

      # The transition index lookup and insert stay together so the audit event
      # cannot escape the effect transaction.
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      # :reek:LongParameterList -- these named fields are the durable audit row.
      def append!(
        transaction,
        effect_key:,
        transition:,
        attempt_number:,
        actor:,
        evidence:,
        now:
      )
        index = transaction.scalar(
          'effect.transition.index',
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_effect_transitions
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
        transaction.execute(
          'effect.transition.insert',
          <<~SQL,
            INSERT INTO tamoz_effect_transitions(
              effect_key, transition_index, transition, attempt_number,
              actor, evidence, created_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            effect_key, index, transition, attempt_number, actor,
            Wire.blob(JSON.generate(evidence)), now
          ]
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists
    end

    private_constant :EffectTransitionLog
  end
end
