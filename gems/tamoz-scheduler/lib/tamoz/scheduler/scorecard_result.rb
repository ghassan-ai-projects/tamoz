# frozen_string_literal: true

module Tamoz
  module Scheduler
    # The validated result of a scorecard summary subprocess.
    class ScorecardResult # :nodoc:
      def initialize(report)
        @report = report
      end

      def summary
        gates = @report['hard_gates']
        result = build_summary(gates)
        required = result.values_at('decision', 'hard_gates_total')
        return result if required.compact.length == required.length

        { 'ok' => false, 'reason' => 'scorecard report is missing required fields' }
      end

      def self.failed(stderr)
        {
          'ok' => false,
          'reason' => 'scorecard failed',
          'stderr_tail' => stderr.to_s.byteslice(0, 4_096)
        }
      end

      def self.invalid_json
        { 'ok' => false, 'reason' => 'scorecard output is not JSON' }
      end

      def self.unavailable(error)
        {
          'ok' => false,
          'reason' => 'scorecard command unavailable',
          'stderr_tail' => error.message.byteslice(0, 4_096)
        }
      end

      def self.gate_counts(gates)
        return [nil, nil] unless gates.is_a?(Array)

        [gates.count { |gate| passed?(gate) }, gates.length]
      end

      def self.passed?(gate)
        gate.is_a?(Hash) && gate['status'] == 'pass'
      end

      private

      def build_summary(gates)
        gate_counts = self.class.gate_counts(gates)
        {
          'ok' => true,
          'decision' => @report['decision'],
          'cases' => @report.dig('corpus', 'case_count'),
          'successes' => @report.dig('aggregate', 'task_successes'),
          'hard_gates_passed' => gate_counts.fetch(0),
          'hard_gates_total' => gate_counts.fetch(1),
          'unsafe_actions' => @report.dig('aggregate', 'unsafe_or_bypassed_actions')
        }
      end
    end
  end
end
