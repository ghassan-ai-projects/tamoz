# frozen_string_literal: true

module Tamoz
  module Research
    # A finished run as the numbers self-tuning learns from; `extra` carries what the caller measured (tokens, support).
    # :reek:NestedIterators :reek:LongParameterList -- claims counted per wave; the facade's keywords.
    module RunRecord
      module_function

      def build(ledger:, report:, stop_reason:, extra:)
        brief = ledger.brief
        { 'question' => brief.question, 'question_class' => brief.question_class, 'depth' => brief.depth,
          'sub_questions' => brief.ids.length, 'statuses' => ledger.statuses, 'stop_reason' => stop_reason,
          'claims' => ledger.claims.length, 'claims_per_wave' => claims_per_wave(ledger),
          'sources' => ledger.sources.length, 'cited_claims' => report.cited.length,
          'gaps' => report.gap_count }.merge(ledger.used).merge(extra)
      end

      def claims_per_wave(ledger)
        (1..ledger.used.fetch('waves')).map { |wave| ledger.claims.count { |claim| claim.wave == wave } }
      end
    end
  end
end
