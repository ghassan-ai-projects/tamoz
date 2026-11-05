# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class AgentMemoryRepositoryCorpus < AgentMemoryCorpus
        SUITE_ID = Verifier::MEMORY_EVAL_SUITE_ID
        SUITE_VERSION = 1

        def cases
          artifacts = case_paths_for(
            'agent_memory_repository', 'agent memory repository corpus'
          ).map { |path| Case.load(path) }
          actual_ids = artifacts.map { |artifact| artifact['case_id'] }.sort
          unless artifacts.any? && actual_ids.uniq == actual_ids
            raise ExecutionError, 'agent memory repository corpus identity mismatch'
          end

          artifacts.freeze
        end

        # This corpus resolves its own definitions and scenario runners while
        # retaining the shared cell contract.
        def run_cell(case_artifact, cell_root:, store:, memory_config:, memory_capture:)
          ensure_agent!
          definition = case_definition(case_artifact)
          unless case_artifact['input'].fetch('payload').fetch('scenario') == definition.fetch('scenario')
            raise ExecutionError, 'agent memory repository scenario mismatch'
          end

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          execution = send(
            "run_#{definition.fetch('scenario')}",
            case_artifact, definition, cell_root:, store:, memory_config:, memory_capture:
          )
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).ceil
          execution.with(
            evidence_complete: execution.evidence_complete &&
              elapsed_ms <= case_artifact['budgets'].fetch('time_ms')
          )
        end

        private

        def run_real_recall_ladder(case_artifact, definition, **cell)
          read_and_answer(case_artifact, definition, cell,
                          { file: 'deploy.rb', content: "DEPLOY_STATE = :staged\n", answer: 'deployment staged' })
        end

        def run_real_sensitive_guard(case_artifact, definition, **cell)
          read_and_answer(case_artifact, definition, cell,
                          { file: 'runbook.txt', content: "1. Rotate the credential. 2. Verify the rotation.\n",
                            answer: 'Rotate then verify.' })
        end
      end
    end
  end
end
