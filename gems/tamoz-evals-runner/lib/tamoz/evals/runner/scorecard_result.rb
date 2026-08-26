# frozen_string_literal: true

module Tamoz
  module Evals
    module Runner
      class ScorecardSummaryConsumer
        # The validated result of a scorecard summary subprocess.
        class ScorecardResult # :nodoc:
          def initialize(report)
            @report = report
          end

          def summary
            return missing_fields unless @report.is_a?(Hash)

            gates = @report['hard_gates']
            result = build_summary(gates)
            required = result.values_at('decision', 'hard_gates_total')
            return result if required.compact.length == required.length

            missing_fields
          end

          def self.failed(stderr, result: nil)
            {
              'ok' => false,
              'reason' => failure_reason(result),
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

          def self.failure_reason(result)
            return 'scorecard failed' unless result
            return 'scorecard timed out' if result.timed_out
            return 'scorecard output truncated' if result.stdout.truncated || result.stderr.truncated
            return 'scorecard terminated' unless result.termination == 'none'

            'scorecard failed'
          end
          private_class_method :failure_reason

          private

          def missing_fields
            { 'ok' => false, 'reason' => 'scorecard report is missing required fields' }
          end

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
  end
end
