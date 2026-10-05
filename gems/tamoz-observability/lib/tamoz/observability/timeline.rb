# frozen_string_literal: true

module Tamoz
  module Observability
    # The ordered events of a window: failures and lifecycle from durable rows, errors from the lossy journal.
    module Timeline
      MAX_EVENTS = 200
      FAILED = %w[failed unknown].freeze

      module_function

      def build(records, journal_documents:, journal_names:, since_ms:, until_ms:)
        events = (durable_events(records) + journal_events(journal_documents, journal_names))
                 .select { |event| event['at_ms'].between?(since_ms, until_ms) }
                 .each_with_index.sort_by { |event, index| [event['at_ms'], index] }.map(&:first)
        Diagnosis.redact({ 'events' => events.last(MAX_EVENTS), 'truncated' => events.length > MAX_EVENTS,
                           'threads_with_failures' => failed_threads(events) })
      end

      def failed_threads(events)
        events.select { |event| event['failure'] }.filter_map { |event| event['thread_id'] }.uniq.sort
      end

      def durable_events(records)
        request_events(records) + checkpoint_events(records) + attempt_events(records) +
          approval_events(records) + occurrence_events(records)
      end

      def request_events(records)
        records.fetch('requests').flat_map do |row|
          key = "#{row['thread_id']}##{row['request_id']}"
          [event(row['created_at_ms'], 'request', key, "#{row['operation']} requested", row.except('failure'))] +
            terminal_request(row, key)
        end
      end

      def terminal_request(row, key)
        return [] unless %w[completed failed].include?(row['status'])

        [event(row['updated_at_ms'], 'request', key, "turn #{row['status']}", row)]
      end

      def checkpoint_events(records)
        records.fetch('checkpoints').select { |row| row['status'] == 'paused' }.map do |row|
          event(row['created_at_ms'], 'checkpoint', row['id'], 'thread paused', row)
        end
      end

      def attempt_events(records)
        records.fetch('effect_attempts').select { |row| FAILED.include?(row['status']) }.map do |row|
          event(row['completed_at_ms'] || row['prepared_at_ms'], 'effect_attempt',
                "#{row['effect_key']}##{row['attempt_number']}", "#{row['operation']} #{row['status']}", row)
        end
      end

      def approval_events(records)
        records.fetch('approval_decisions').flat_map do |row|
          asked = event(row['created_at_ms'], 'approval', row['decision_id'], "#{row['tool']} #{row['verdict']}", row)
          next [asked] unless row['resolved_at_ms']

          [asked, event(row['resolved_at_ms'], 'approval', row['decision_id'], "#{row['tool']} #{row['answer']}", row)]
        end
      end

      def occurrence_events(records)
        records.fetch('occurrences').select { |row| FAILED.include?(row['state']) }.map do |row|
          event(row['updated_at_ms'], 'occurrence', row['occurrence_id'], "occurrence #{row['state']}", row)
        end
      end

      def journal_events(documents, names)
        documents.select { |document| names.include?(document['name']) }.map do |document|
          {
            'at_ms' => document['observed_at_ms'].to_i, 'kind' => 'journal', 'source' => 'journal',
            'key' => document['name'],
            'what' => Tamoz::Core.scrub_secrets(document.dig('attributes', 'reason') || document['name']),
            'thread_id' => document.dig('correlation', 'thread_id')
          }.compact
        end
      end

      def event(at_ms, kind, key, what, row)
        {
          'at_ms' => at_ms.to_i, 'kind' => kind, 'source' => 'durable', 'key' => key, 'what' => what,
          'thread_id' => row['thread_id'], 'database' => row['source'], 'failure' => row['failure']
        }.compact
      end
    end
  end
end
