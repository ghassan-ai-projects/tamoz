# frozen_string_literal: true

module Tamoz
  module Observability
    module Diagnosis
      # Counts and latencies over the window, computed from durable rows only.
      module Summary
        MAX_OPERATIONS = 15
        FAILED = %w[failed unknown].freeze

        module_function

        def build(records, since_ms:, until_ms:)
          {
            'requests' => status_counts(records.fetch('requests'), since_ms..until_ms),
            'effects' => status_counts(records.fetch('effects'), since_ms..until_ms),
            'operations' => operations(records.fetch('effect_attempts'), since_ms..until_ms)
          }
        end

        def status_counts(rows, window)
          rows.select { |row| window.cover?(row['updated_at_ms'].to_i) }.map { |row| row['status'] }.tally.sort.to_h
        end

        def operations(attempts, window)
          observed = attempts.select do |row|
            window.cover?((row['completed_at_ms'] || row['prepared_at_ms']).to_i) && row['operation']
          end
          observed.group_by { |row| row['operation'] }
                  .map { |operation, rows| operation_line(operation, rows) }
                  .sort_by { |line| [-line['attempts'], line['operation']] }
                  .first(MAX_OPERATIONS)
        end

        def operation_line(operation, rows)
          durations = rows.filter_map { |row| duration(row) }.sort
          {
            'operation' => operation,
            'attempts' => rows.length,
            'failed' => rows.count { |row| FAILED.include?(row['status']) },
            'p50_ms' => percentile(durations, 0.5),
            'p95_ms' => percentile(durations, 0.95)
          }
        end

        def duration(row)
          started = row['started_at_ms']
          completed = row['completed_at_ms']
          started && completed ? completed - started : nil
        end

        def percentile(sorted, rank)
          return nil if sorted.empty?

          sorted[((sorted.length * rank).ceil - 1).clamp(0, sorted.length - 1)]
        end
      end
    end
  end
end
