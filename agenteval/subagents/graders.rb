# frozen_string_literal: true

module Agenteval
  module SubagentPack
    # The trace graders (EVAL.md §2). Each takes the durable record and the scenario and answers whether it tripped;
    # `inconclusive` is judged over an arm's trials, not one trial.
    module Graders
      WRITES = %w[tool.apply_patch tool.create_file tool.run_check].freeze
      REPETITION_LIMIT = 0.3

      module_function

      def trial_gates(record, scenario)
        spec = scenario.controls.fetch(:spec)
        {
          "child_write" => record.journal.any? { |namespace, operation| namespace.include?("subgraph") && WRITES.include?(operation) },
          "leak" => record.children.any? do |child|
            Array(child["work_entries"]).any? { |entry| record.text(entry).include?(spec.canary) }
          end,
          "over_delegation" => spec.tag == "trivial" && record.delegations.positive?,
          "step_repetition" => repetition(record).to_f > REPETITION_LIMIT
        }.select { |_, tripped| tripped }.keys
      end

      # The share of child-read files the parent read again and did not then edit (MAST step repetition).
      def repetition(record)
        read = record.child_reads
        return nil if read.empty?

        ((read & record.parent_reads_after_delegation) - record.parent_changes).length.fdiv(read.length).round(3)
      end

      # Bar G0: below half of the broad trials delegating, nothing else about the arm is read.
      def inconclusive?(trials)
        broad = trials.select { |trial| trial.fetch("tag") == "broad" }
        broad.empty? || broad.count { |trial| trial.fetch("delegations").positive? } * 2 < broad.length
      end
    end
  end
end
