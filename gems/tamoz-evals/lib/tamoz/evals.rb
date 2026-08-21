# frozen_string_literal: true

require "pathname"

# The harness subtree (agent_smoke_corpus, sqlite_scenario_runtime, etc.)
# references Tamoz::Agent::*, Tamoz::SQLite::*, and Tamoz::Mcp::* directly;
# these must be real requires (matching the gemspec dependencies below), not
# an accident of Gemfile load order.
require "tamoz/core"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/mcp"

require_relative "evals/version"
require_relative "evals/errors"
require_relative "evals/deep_freeze"
require_relative "evals/canonical_json"
require_relative "evals/duplicate_key_detector"
require_relative "evals/schema"
require_relative "evals/artifact"
require_relative "evals/verifier"
require_relative "evals/case"
require_relative "evals/evidence"
require_relative "evals/result"
require_relative "evals/harness/sqlite_scenario_registry"
require_relative "evals/harness/sqlite_scenario_fault_gate"
require_relative "evals/harness/sqlite_scenario_runtime"
require_relative "evals/harness/sqlite_scenario_driver"
require_relative "evals/harness/sqlite_convergence_probe"
require_relative "evals/harness/sqlite_trace_recorder"
require_relative "evals/harness/sqlite_trace_selector_deriver"
require_relative "evals/harness/sqlite_trace_manifest_verifier"
require_relative "evals/harness/subprocess_runner"
require_relative "evals/harness/sqlite_selector_control"
require_relative "evals/harness/sqlite_selector_control_stopper"
require_relative "evals/harness/sqlite_selector_control_intervention"
require_relative "evals/harness/agent_smoke_corpus"
require_relative "evals/harness/agent_run_audit"
require_relative "evals/harness/agent_smoke_scorecard"
require_relative "evals/harness/memory_store"
require_relative "evals/harness/memory_retrieval"
require_relative "evals/harness/memory_envelope"
require_relative "evals/harness/memory_holdout"
require_relative "evals/harness/agent_memory_corpus"
require_relative "evals/harness/memory_cell"
require_relative "evals/harness/memory_treatment_profile"
require_relative "evals/harness/memory_repository_adapter"
require_relative "evals/harness/agent_memory_repository_corpus"
require_relative "evals/harness/heuristic_corpus"
require_relative "evals/harness/heuristic_paired_evaluation"
require_relative "evals/benchmark/metrics"
require_relative "evals/benchmark/baselines"
require_relative "evals/benchmark/comparison"
require_relative "evals/benchmark/report"
require_relative "evals/benchmark/readiness"
require_relative "evals/benchmark/scoreboard"
require_relative "evals/benchmark/environment_loader"
require_relative "evals/benchmark/openclaw_mission_runner"
require_relative "evals/benchmark/cell_extractor"
require_relative "evals/benchmark/comparison_executor"
require_relative "evals/benchmark/leak_scan"
require_relative "evals/cli"

module Tamoz
  module Evals
    module_function

    def verify(path)
      Verifier.new.verify(path)
    end
  end
end
