# frozen_string_literal: true

module Tamoz
  module Observability
    # One thread's decision record — requests, executions, effects and approvals — built from durable rows.
    module Explanation
      FORMAT_VERSION = 1
      APPROVAL_LINKS = %i[database time_window].freeze
      TERMINAL_REQUESTS = %w[completed failed].freeze

      module_function

      def build(records, thread:, approval_link:, request: nil, now_ms: nil)
        raise ValidationError, "approval_link must be one of #{APPROVAL_LINKS.join(', ')}" unless
          APPROVAL_LINKS.include?(approval_link)

        requests = selected_requests(records, thread, request)
        Diagnosis.redact({
                           'format_version' => FORMAT_VERSION, 'thread_id' => thread,
                           'outcome' => requests.last&.fetch('status'),
                           'requests' => requests.map { |row| request_line(row) },
                           'executions' => executions(records, requests, request:),
                           'approvals' => approvals(records, requests, request ? :time_window : approval_link,
                                                    now_ms:)
                         })
      end

      def selected_requests(records, thread, request)
        rows = records.fetch('requests').select { |row| row['thread_id'] == thread }
        rows = rows.select { |row| row['request_id'] == request } if request
        if rows.empty?
          raise ValidationError,
                "no durable request for thread #{thread}#{" request #{request}" if request}"
        end

        rows.sort_by { |row| [row['created_at_ms'], row['request_id']] }
      end

      def request_line(row)
        row.slice('request_id', 'operation', 'status', 'execution_id', 'created_at_ms', 'updated_at_ms', 'failure')
           .compact
      end

      def executions(records, requests, request: nil)
        ids = requests.filter_map { |row| row['execution_id'] }.uniq
        attempts = records.fetch('effect_attempts').group_by { |row| row['effect_key'] }
        ids.map do |execution|
          {
            'execution_id' => execution,
            'checkpoint_scope' => 'execution', 'checkpoints' => checkpoints(records, execution),
            'effects' => effects(records, execution, attempts, request:)
          }
        end
      end

      def checkpoints(records, execution)
        records.fetch('checkpoints').select { |row| row['execution_id'] == execution }
                                    .sort_by { |row| row['sequence'] }
                                    .map do |row|
          row.slice(
            'sequence', 'status', 'graph_name', 'graph_version', 'created_at_ms'
          )
        end
      end

      def effects(records, execution, attempts, request: nil)
        rows = records.fetch('effects').select do |row|
          row['execution_id'] == execution && (!request || row['request_id'] == request)
        end
        rows.sort_by { |row| [row['created_at_ms'], row['effect_key']] }
            .map { |row| effect_line(row, attempts.fetch(row['effect_key'], [])) }
      end

      def effect_line(row, attempts)
        ordered = attempts.sort_by { |attempt| attempt['attempt_number'] }
        row.slice('effect_key', 'request_id', 'operation', 'safety', 'status', 'task_id', 'call_index', 'created_at_ms')
           .merge('attempts' => ordered.map { |attempt| attempt_line(attempt) })
      end

      def attempt_line(attempt)
        started = attempt['started_at_ms']
        completed = attempt['completed_at_ms']
        {
          'attempt' => attempt['attempt_number'], 'status' => attempt['status'],
          'duration_ms' => started && completed ? completed - started : nil, 'failure' => attempt['failure']
        }.compact
      end

      def approvals(records, requests, link, now_ms:)
        decisions = records.fetch('approval_decisions')
        decisions = within(decisions, requests, now_ms) if link == :time_window
        {
          'link' => link.to_s,
          'decisions' => decisions.sort_by { |row| [row['created_at_ms'], row['decision_id']] }
                                  .map { |row| decision_line(row) }
        }
      end

      def within(decisions, requests, now_ms)
        from = requests.map { |row| row['created_at_ms'] }.min
        to = requests.map { |row| window_end(row, now_ms) }.max
        decisions.select do |row|
          [row['created_at_ms'], row['resolved_at_ms']].compact.any? { |at| at.between?(from, to) }
        end
      end

      def window_end(request, now_ms)
        TERMINAL_REQUESTS.include?(request['status']) ? request['updated_at_ms'] : now_ms || request['updated_at_ms']
      end

      def decision_line(row)
        row.slice('decision_id', 'session_id', 'tool', 'verb', 'tier', 'rule_id', 'verdict', 'policy_rev',
                  'actor_evidence', 'resolved_at_ms', 'created_at_ms')
           .merge('decision' => decision(row)).compact
      end

      def decision(row)
        return "policy_#{row['verdict']}" unless row['verdict'] == 'ask'

        row['answer'] || 'unanswered'
      end
    end
  end
end
