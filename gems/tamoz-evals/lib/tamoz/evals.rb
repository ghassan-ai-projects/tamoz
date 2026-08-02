# frozen_string_literal: true

require "pathname"

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
require_relative "evals/cli"

module Tamoz
  module Evals
    module_function

    def verify(path)
      Verifier.new.verify(path)
    end
  end
end
