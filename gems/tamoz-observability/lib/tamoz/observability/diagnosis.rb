# frozen_string_literal: true

require_relative 'diagnosis/rules'
require_relative 'diagnosis/finding'
require_relative 'diagnosis/detectors'
require_relative 'diagnosis/summary'
require_relative 'diagnosis/report'
require_relative 'diagnosis/markdown'

module Tamoz
  module Observability
    # Read-only self-diagnosis: rules that are data, run over durable records and the journal's health.
    module Diagnosis
      Source = Data.define(:name, :records, :limit)

      module_function

      def redact(value)
        case value
        when Hash then value.to_h { |key, entry| [redact(key), redact(entry)] }
        when Array then value.map { |entry| redact(entry) }
        when String then Tamoz::Core.scrub_secrets(value)
        else value
        end
      end

      def run(sources:, journal:, now_ms:, since_ms:, rules: Rules.default)
        records = merge(sources)
        context = Detectors::Context.new(records:, journal_documents: journal.fetch(:documents),
                                         drops: journal.fetch(:drops), now_ms:, since_ms:)
        findings = rules.rules.flat_map { |rule| Detectors.run(rule, context) }
        Report.new(
          generated_at_ms: now_ms, since_ms:, rules_digest: rules.digest,
          sources: sources.map { |source| source_summary(source) },
          journal: { 'documents' => journal.fetch(:documents).length, 'drops' => journal.fetch(:drops).values.sum },
          degraded_reasons: degraded_reasons(sources, journal),
          summary: Summary.build(records, since_ms:, until_ms: now_ms),
          findings: sort(findings, rules)
        )
      end

      def merge(sources)
        TelemetryReader::KINDS.to_h do |kind|
          rows = sources.flat_map do |source|
            source.records.fetch(kind.to_s, []).map { |row| row.merge('source' => source.name) }
          end
          [kind.to_s, rows]
        end.then { |records| joined(records, sources) }
      end

      def joined(records, sources)
        records.merge('effect_attempts' => with_operations(records.fetch('effect_attempts'), sources),
                      'effects' => with_latest_failures(records.fetch('effects'), records.fetch('effect_attempts')))
      end

      def with_latest_failures(effects, attempts)
        latest = attempts.group_by { |attempt| [attempt['source'], attempt['effect_key']] }
                         .transform_values { |rows| rows.max_by { |attempt| attempt['attempt_number'].to_i } }
        effects.map do |effect|
          failure = latest[[effect['source'], effect['effect_key']]]&.fetch('failure', nil)
          failure ? effect.merge('failure' => failure) : effect
        end
      end

      def with_operations(attempts, sources)
        effects = sources.flat_map do |source|
          source.records.fetch('effects', []).map { |row| [[source.name, row['effect_key']], row] }
        end.to_h
        attempts.map do |attempt|
          effect = effects.fetch([attempt['source'], attempt['effect_key']], {})
          attempt.merge('operation' => effect['operation'], 'thread_id' => effect['thread_id'])
        end
      end

      def source_summary(source)
        rows = source.records.transform_values(&:length)
        { 'name' => source.name, 'rows' => rows.sort.to_h, 'truncated' => truncated(source).sort }
      end

      def truncated(source)
        source.records.select { |_kind, rows| rows.length >= source.limit }.keys
      end

      def degraded_reasons(sources, journal)
        reasons = sources.flat_map do |source|
          truncated(source).map { |kind| "#{source.name}: #{kind} reached the row limit #{source.limit}" }
        end
        reasons.concat(journal.fetch(:unreadable).map do |file|
          "the telemetry journal health file #{file} cannot be read; its dropped-signal count is unknown"
        end)
        drops = journal.fetch(:drops).values.sum
        reasons << "the telemetry journal counted #{drops} dropped signals" if drops.positive?
        reasons.sort
      end

      def sort(findings, rules)
        findings.sort_by do |finding|
          [rules.severity_rank(finding.severity), -finding.count, finding.rule_id, finding.id]
        end
      end
    end
  end
end
