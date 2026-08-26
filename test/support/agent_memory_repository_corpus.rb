# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # P11-ED: the real-adapter treatment corpus. Same suite identity and
      # mandatory `treatments.expected_delta` (E8) as the DR-3 memory corpus,
      # but the seed records are WORD-ALIGNED to their tasks: the production SQL
      # search (P11-B) ANDs query terms at word boundaries over the indexed
      # statement, and a sensitive record's searchable surface is only its
      # layer/class (sensitive statements are never indexed). Every record's
      # `match_keys` are the vocabulary the real adapter queries with, so the
      # treatment ladder and the non-vacuous hard-zero sweep are deterministic
      # over the REAL retrieval path. The runners reuse the DR-3 cell runner
      # (`AgentSmokeCorpus#execute` with the store/memory_config/memory_capture
      # seam); per-cell isolation, expected_delta, and the CI=injection /
      # live=attribution split are preserved.
      class AgentMemoryRepositoryCorpus < AgentMemoryCorpus
        SUITE_ID = Verifier::MEMORY_EVAL_SUITE_ID
        SUITE_VERSION = 1
        def initialize(input_manifest: nil, case_root: nil, scripted_model_factory: nil,
                       scripted_model_script_path: nil, memory_records: nil)
          super(input_manifest:, case_root:, scripted_model_factory:, scripted_model_script_path:,
                memory_records:)
        end

        def cases
          artifacts = case_paths_for(
            "agent_memory_repository", "agent memory repository corpus"
          ).map { |path| Case.load(path) }
          actual_ids = artifacts.map { |artifact| artifact["case_id"] }.sort
          unless artifacts.any? && actual_ids.uniq == actual_ids
            raise ExecutionError, "agent memory repository corpus identity mismatch"
          end

          artifacts.freeze
        end

        # This corpus resolves its own definitions and scenario runners while
        # retaining the shared cell contract.
        def run_cell(case_artifact, cell_root:, store:, memory_config:, memory_capture:)
          ensure_agent!
          definition = case_definition(case_artifact)
          unless case_artifact["input"].fetch("payload").fetch("scenario") == definition.fetch("scenario")
            raise ExecutionError, "agent memory repository scenario mismatch"
          end

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          execution = send(
            "run_#{definition.fetch("scenario")}",
            case_artifact, definition, cell_root:, store:, memory_config:, memory_capture:
          )
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).ceil
          execution.with(
            evidence_complete: execution.evidence_complete &&
              elapsed_ms <= case_artifact["budgets"].fetch("time_ms")
          )
        end

        private

        def run_real_recall_ladder(case_artifact, definition, cell_root:, store:, memory_config:, memory_capture:)
          workspace = memory_workspace(cell_root)
          File.write(File.join(workspace, "deploy.rb"), "DEPLOY_STATE = :staged\n")
          model = scripted_model(
            plans: [plan(read_step("deploy.rb"))],
            reviews: 1,
            verification: verified("deployment staged", true)
          )
          execute(
            case_artifact,
            root: workspace,
            model:,
            task: definition.fetch("task"),
            store:,
            memory_config:,
            memory_capture:,
            oracle: lambda do |result, _events|
              result&.satisfied == true && result.answer == "deployment staged"
            end,
            allowed_tools: %w[read_file]
          )
        end

        def run_real_sensitive_guard(case_artifact, definition, cell_root:, store:, memory_config:, memory_capture:)
          workspace = memory_workspace(cell_root)
          File.write(
            File.join(workspace, "runbook.txt"),
            "1. Rotate the credential. 2. Verify the rotation.\n"
          )
          model = scripted_model(
            plans: [plan(read_step("runbook.txt"))],
            reviews: 1,
            verification: verified("Rotate then verify.", true)
          )
          execute(
            case_artifact,
            root: workspace,
            model:,
            task: definition.fetch("task"),
            store:,
            memory_config:,
            memory_capture:,
            oracle: lambda do |result, _events|
              result&.satisfied == true && result.answer == "Rotate then verify."
            end,
            allowed_tools: %w[read_file]
          )
        end
      end
    end
  end
end
