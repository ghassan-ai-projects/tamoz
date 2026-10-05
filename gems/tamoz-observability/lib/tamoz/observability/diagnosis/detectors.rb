# frozen_string_literal: true

module Tamoz
  module Observability
    module Diagnosis
      # The closed set of detectors a rule may name; each turns rows into findings and nothing else.
      module Detectors
        Context = Data.define(:records, :journal_documents, :drops, :now_ms, :since_ms) do
          def in_window?(time_ms) = time_ms.to_i.between?(since_ms, now_ms)
        end

        MINUTE_MS = 60_000

        module_function

        def run(rule, context)
          case rule.detector
          when 'status' then status(rule, context)
          when 'age' then age(rule, context)
          when 'failure_rate' then failure_rate(rule, context)
          when 'failure_groups' then failure_groups(rule, context)
          when 'journal_events' then journal_events(rule, context)
          when 'telemetry_loss' then telemetry_loss(rule, context)
          end
        end

        def status(rule, context)
          one_finding(rule, rows(rule, context))
        end

        def age(rule, context)
          cutoff_ms = context.now_ms - (rule.older_than_minutes * MINUTE_MS)
          one_finding(rule, rows(rule, context).select { |row| row.fetch(rule.time_field).to_i < cutoff_ms })
        end

        def failure_rate(rule, context)
          settled = rows(rule, context, windowed: true).select { |row| rule.settled_values.include?(row['status']) }
          failed = settled.select { |row| rule.failed_values.include?(row['status']) }
          return [] if settled.length < rule.min_count
          return [] unless failed.length.fdiv(settled.length) > rule.max_failure_ratio

          [Findings.from_rows(rule, failed, kind: rule.kind, group: 'all', detail: rate_detail(settled, failed))]
        end

        def failure_groups(rule, context)
          rows(rule, context, windowed: true)
            .group_by { |row| failure_label(row) }
            .select { |_label, group| group.length >= rule.min_count }
            .map do |label, group|
              Findings.from_rows(rule, group, kind: rule.kind, group: label, detail: { 'failure' => label })
            end
        end

        def journal_events(rule, context)
          named = context.journal_documents.select do |document|
            rule.names.include?(document['name']) && context.in_window?(document['observed_at_ms'])
          end
          named.group_by { |document| document['name'] }
               .select { |_name, documents| documents.length >= rule.min_count }
               .map { |name, documents| Findings.from_documents(rule, documents, group: name) }
        end

        def telemetry_loss(rule, context)
          return [] if context.drops.values.sum < rule.min_count

          [Findings.from_drops(rule, context.drops)]
        end

        def rows(rule, context, windowed: false)
          context.records.fetch(rule.kind, []).select do |row|
            matches?(rule, row) && (!windowed || context.in_window?(row[rule.time_field]))
          end
        end

        def matches?(rule, row)
          (rule.field_values.nil? || rule.field_values.include?(row[rule.field])) &&
            rule.missing.all? { |field| row[field].nil? } &&
            row['operation'].to_s.start_with?(rule.operation_prefix)
        end

        def one_finding(rule, rows)
          rows.empty? ? [] : [Findings.from_rows(rule, rows, kind: rule.kind, group: 'all')]
        end

        def rate_detail(settled, failed)
          {
            'settled' => settled.length,
            'failed' => failed.length,
            'by_operation' => failed.map { |row| row.fetch('operation') }.tally.sort.to_h
          }
        end

        def failure_label(row)
          failure = row['failure'] || {}
          [failure['class'] || 'unclassified', failure['code']].compact.join('/')
        end
      end
    end
  end
end
