# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/autonomy_case"

# `tamoz improve promote` — the durable, human-gated operator command that records
# a vetted candidate bundle as a behavior-version promotion. Proven against a real
# runtime directory and a real Memory::Engine, with the bundle produced by the
# real improvement pipeline.
class CLIImprovePromoteTest < Minitest::Test
  include AutonomyCase
  Harness = Tamoz::Evals::Harness

  def enable_memory(rt)
    path = File.join(rt.dir, "config.yaml")
    document = Psych.safe_load_file(path)
    document["sources"] = {"memory" => {"enabled" => true, "tenant" => "acme", "owner" => "operator"}}
    File.write(path, Psych.dump(document))
  end

  # A real pipeline bundle, before -> after chosen to advance the engine default
  # (tamoz.agent.session/1).
  def write_bundle(path)
    Harness::HeuristicCorpus.create(inputs: RunnerInputs.heuristic) do |corpus|
      bundle = Harness::HeuristicImprovementPipeline.new(
        corpus:, generator_principal: "principal.generator", evaluator_principal: "principal.evaluator",
        promoter_principal: "principal.operator",
        behavior_version_before: "tamoz.agent.session/1", behavior_version_after: "tamoz.agent.session/2",
        rollback_snapshot_digest: "sha256:#{"a" * 64}", regression_tasks: RunnerInputs.regression_tasks
      ).run
      assert bundle.promotable?, "the fixture bundle must be promotion-ready"
      File.write(path, JSON.generate(bundle.to_h))
    end
  end

  def test_missing_bundle_is_a_usage_error
    with_runtime do |rt|
      status = rt.cli(%w[improve promote --approval human:operator-1])
      assert_equal 2, status
      assert_match(/--bundle/, rt.err)
    end
  end

  def test_approval_must_be_a_human_gate
    with_runtime do |rt|
      bundle = File.join(rt.dir, "bundle.json")
      write_bundle(bundle)
      status = rt.cli(%W[improve promote --bundle #{bundle} --approval yes])
      assert_equal 2, status
      assert_match(/human:/, rt.err)
    end
  end

  def test_promote_records_a_durable_transition
    with_runtime do |rt|
      enable_memory(rt)
      bundle = File.join(rt.dir, "bundle.json")
      write_bundle(bundle)

      status = rt.cli(%W[improve promote --bundle #{bundle} --approval human:operator-1 --actor operator])

      assert_equal 0, status, rt.err
      assert_match(/recorded .*pending activation/, rt.out)

      # The transition is really in the durable store, pending activation.
      adapter = Tamoz::SQLite::Adapter.new(path: db_path(rt))
      engine = Tamoz::Agent::Memory::Engine.new(tenant: "acme", adapter:)
      pending = engine.transitions.active
      assert_equal "tamoz.agent.session/1", pending.fetch("active_version"),
                   "a recorded promotion does not activate until the next thread's first intake"
    ensure
      adapter&.close
    end
  end

  def db_path(rt)
    Dir[File.join(rt.dir, "**", "*.sqlite3")].first
  end
end
