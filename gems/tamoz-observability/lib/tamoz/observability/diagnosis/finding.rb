# frozen_string_literal: true

module Tamoz
  module Observability
    module Diagnosis
      Finding = Data.define(
        :id, :rule_id, :severity, :category, :title, :action, :count,
        :first_seen_ms, :last_seen_ms, :evidence, :detail
      ) do
        def to_h = super.transform_keys(&:to_s)
      end

      # Builds findings with stable identities and bounded evidence from rows, journal documents or drop counts.
      module Findings
        DIGEST_DOMAIN = "tamoz.observability.diagnosis.finding\n"
        MAX_EVIDENCE = 10
        KEY_FIELDS = {
          'requests' => %w[thread_id request_id],
          'effects' => %w[effect_key],
          'effect_attempts' => %w[effect_key attempt_number],
          'checkpoints' => %w[id],
          'approval_decisions' => %w[decision_id],
          'occurrences' => %w[occurrence_id]
        }.freeze
        TIME_FIELDS = %w[updated_at_ms completed_at_ms prepared_at_ms created_at_ms].freeze

        def self.from_rows(rule, rows, kind:, group:, detail: {})
          ordered = rows.sort_by { |row| [-observed_at(row), key(kind, row)] }
          times = rows.map { |row| observed_at(row) }
          build(rule, group:, times:, detail:, evidence: ordered.first(MAX_EVIDENCE).map { |row| evidence(kind, row) })
        end

        def self.from_documents(rule, documents, group:)
          ordered = documents.sort_by { |document| -document['observed_at_ms'].to_i }
          build(rule, group:, detail: {}, times: documents.map { |document| document['observed_at_ms'].to_i },
                      evidence: ordered.first(MAX_EVIDENCE).map { |document| journal_evidence(document) })
        end

        def self.from_drops(rule, drops)
          build(rule, group: 'journal', times: [], evidence: [], detail: { 'drops' => drops.sort.to_h })
            .with(count: drops.values.sum)
        end

        def self.build(rule, group:, times:, evidence:, detail:)
          Finding.new(
            id: Tamoz::Core.digest(DIGEST_DOMAIN, [rule.id, group]),
            rule_id: rule.id, severity: rule.severity, category: rule.category,
            title: rule.title, action: rule.action, count: times.length,
            first_seen_ms: times.min, last_seen_ms: times.max,
            evidence: Diagnosis.redact(evidence), detail: Diagnosis.redact(detail)
          )
        end

        def self.key(kind, row)
          KEY_FIELDS.fetch(kind).map { |field| row.fetch(field) }.join('#')
        end

        def self.observed_at(row)
          TIME_FIELDS.lazy.map { |field| row[field] }.find(&:itself).to_i
        end

        def self.evidence(kind, row)
          { 'kind' => kind, 'key' => key(kind, row) }.merge(row.reject { |field, _| field.end_with?('_digest') })
        end

        def self.journal_evidence(document)
          {
            'kind' => 'journal',
            'key' => "#{document['name']}@#{document['observed_at_ms']}",
            'name' => document['name'],
            'observed_at_ms' => document['observed_at_ms'],
            'correlation' => document['correlation'] || {},
            'reason' => document.dig('attributes', 'reason')&.then { |reason| Tamoz::Core.scrub_secrets(reason) }
          }
        end

        private_class_method :build, :evidence, :journal_evidence
      end
    end
  end
end
