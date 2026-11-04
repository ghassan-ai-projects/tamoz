# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # The deterministic gates (§9) a consolidation candidate must pass before the model is called.
      module ConsolidationGates
        # Evidence quality OR recurrence for the risk class: recurrence is
        # measured as the number of distinct supporting sources.
        GATE_CHECKS = {
          provenance: ['provenance: no source references', ->(candidate, _limits) { candidate.source_refs.empty? }],
          scope: ['scope: tenant scope missing',
                  ->(candidate, _limits) { candidate.scopes.fetch('tenant', '').empty? }],
          recurrence: ['recurrence: insufficient evidence quality',
                       ->(candidate, _limits) { candidate.source_refs.length < 2 && candidate.klass != :policy }],
          diversity: ['diversity: single-source synthesis',
                      ->(candidate, _limits) { candidate.source_refs.map { |ref| ref['identity'] }.uniq.length < 2 }],
          confidence: ['confidence: below threshold', ->(candidate, _limits) { candidate.confidence.to_f < 0.5 }],
          taint: ['taint: recalled content cannot consolidate', ->(candidate, _limits) { candidate.recalled? }],
          budget: ['budget: statement exceeds limit',
                   ->(candidate, limits) { candidate.statement.bytesize > limits.fetch(:max_statement_bytes) }]
        }.freeze
        DETERMINISTIC_GATES = GATE_CHECKS.keys.freeze

        Candidate = Data.define(:candidate, :gates, :reason)

        private

        def evaluate_gates(candidates)
          accepted = []
          rejected = []
          candidates.each do |candidate|
            gates, reason = deterministic_gates(candidate)
            if reason
              rejected << Candidate.new(candidate:, gates: gates, reason: reason)
            else
              accepted << Candidate.new(candidate:, gates: gates, reason: nil)
            end
          end
          { accepted:, rejected:, passed_gates: DETERMINISTIC_GATES }
        end

        def deterministic_gates(candidate)
          gates = []
          GATE_CHECKS.each do |gate, (failure, failed)|
            return [gates, failure] if failed.call(candidate, @limits)

            gates << gate
          end
          [gates, nil]
        end
      end
    end
  end
end
