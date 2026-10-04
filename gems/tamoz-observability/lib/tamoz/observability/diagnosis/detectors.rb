# frozen_string_literal: true

module Tamoz
  module Observability
    module Diagnosis
      # The closed set of detectors a rule may name; each turns rows into findings and nothing else.
      module Detectors
        Context = Data.define(:records, :journal_documents, :drops, :now_ms, :since_ms)

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
          rows = matching(rule, context)
          rows.empty? ? [] : [Findings.from_rows(rule, rows, kind: rule.fetch('kind'), group: 'all')]
        end

        def age(rule, context)
          cutoff = context.now_ms - (rule.fetch('older_than_minutes') * MINUTE_MS)
          rows = matching(rule, context).select { |row| row.fetch(rule.fetch('time_field')).to_i < cutoff }
          rows.empty? ? [] : [Findings.from_rows(rule, rows, kind: rule.fetch('kind'), group: 'all')]
        end

        def failure_rate(rule, context)
          settled = windowed(rule, context).select do |row|
            row.fetch('operation').start_with?(rule.fetch('operation_prefix')) &&
              rule.fetch('settled_values').include?(row.fetch('status'))
          end
          failed = settled.select { |row| rule.fetch('failed_values').include?(row.fetch('status')) }
          return [] unless rate_exceeded?(rule, settled.length, failed.length)

          [Findings.from_rows(rule, failed, kind: rule.fetch('kind'), group: 'all',
                                            detail: rate_detail(settled, failed))]
        end

        def failure_groups(rule, context)
          rows = windowed(rule, context).select { |row| failure_matches?(rule, row) }
          rows.group_by { |row| failure_group(row) }
              .select { |_group, members| members.length >= rule.fetch('min_count') }
              .map do |group, members|
                Findings.from_rows(rule, members, kind: rule.fetch('kind'), group:,
                                                  detail: { 'failure' => group })
              end
        end

        def failure_matches?(rule, row)
          rule.fetch('values').include?(row.fetch(rule.fetch('field'))) &&
            row['operation'].to_s.start_with?(rule['operation_prefix'].to_s)
        end

        def journal_events(rule, context)
          context.journal_documents
                 .select { |document| rule.fetch('names').include?(document['name']) }
                 .select { |document| document['observed_at_ms'].to_i.between?(context.since_ms, context.now_ms) }
                 .group_by { |document| document['name'] }
                 .select { |_name, documents| documents.length >= rule.fetch('min_count') }
                 .map { |name, documents| Findings.from_documents(rule, documents, group: name) }
        end

        def telemetry_loss(rule, context)
          return [] if context.drops.values.sum < rule.fetch('min_count')

          [Findings.from_drops(rule, context.drops)]
        end

        def matching(rule, context)
          context.records.fetch(rule.fetch('kind'), []).select do |row|
            rule.fetch('values').include?(row[rule.fetch('field')]) &&
              Array(rule['missing']).all? { |field| row[field].nil? }
          end
        end

        def windowed(rule, context)
          context.records.fetch(rule.fetch('kind'), []).select do |row|
            row[rule.fetch('time_field')].to_i.between?(context.since_ms, context.now_ms)
          end
        end

        def rate_exceeded?(rule, settled, failed)
          settled >= rule.fetch('min_count') && failed.fdiv(settled) > rule.fetch('max_failure_ratio')
        end

        def rate_detail(settled, failed)
          {
            'settled' => settled.length,
            'failed' => failed.length,
            'by_operation' => failed.map { |row| row.fetch('operation') }.tally.sort.to_h
          }
        end

        def failure_group(row)
          failure = row['failure'] || {}
          [failure['class'] || 'unclassified', failure['code']].compact.join('/')
        end
      end
    end
  end
end
