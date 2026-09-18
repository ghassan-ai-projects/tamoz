# frozen_string_literal: true

require_relative 'test_helper'

# The discrimination gate for the intelligence-mission surface (GAPS-20260918 G1,
# remaining half). The comms oracles compute hard-zeros from a fact snapshot; the
# mission surface is the other shape — the executor reports the evidence and the
# runner + Readiness are the graders. So the control agents here are executors,
# and the claim proved is that the GATE accepts a correct run and rejects every
# incorrect one, over the REAL committed catalog (all nine missions).
#
#   oracle    — reports complete, clean evidence: every mission is `ready`.
#   null      — did nothing: every mission is `blocked`.
#   cheap     — claims ready with empty evidence: every mission is `blocked`.
#   adversary — claims ready but a hard-zero failed: every mission is `failed`
#               and Readiness names the gate it tripped.
#
# This mirrors agenteval's V1 and the comms control suite: `controls_passed` on
# this surface is still a caller-supplied flag, and this is the offline evidence
# that would earn it.
class OpenclawMissionControlsTest < Minitest::Test
  Runner = Tamoz::Evals::Benchmark::OpenclawMissionRunner
  Readiness = Tamoz::Evals::Benchmark::Readiness
  CATALOG_PATH = 'documentation/benchmark/OPENCLAW_MISSIONS.json'

  def catalog
    @catalog ||= JSON.parse(File.read(CATALOG_PATH, encoding: Encoding::UTF_8))
  end

  def mission_ids
    catalog.fetch('missions').map { |mission| mission.fetch('id') }
  end

  def capabilities
    state = Readiness::CAPABILITY_FIELDS.to_h { |field| [field, true] }
    catalog.fetch('missions').flat_map { |m| m.fetch('required_capabilities') }.uniq.to_h { |cap| [cap, state] }
  end

  def surface_executions(mission)
    mission.fetch('surfaces').to_h do |surface|
      [surface, {
        'status' => 'executed',
        'provenance' => { 'surface' => surface, 'run_kind' => 'fixture',
                          'provider' => 'fixture-provider', 'model' => 'fixture-model' }
      }]
    end
  end

  def run_controls(directory, executor)
    Runner.new(
      protocol: { 'benchmark_protocol_version' => 'openclaw.v1' }, catalog:, run_kind: 'fixture',
      provider: 'fixture-provider', model: 'fixture-model', artifact_root: 'fixtures/controls',
      artifact_base: directory, git_revision: "sha256:#{'c' * 64}", config_sha256: "sha256:#{'d' * 64}",
      graph: { 'name' => 'tamoz.agent.session', 'version' => '2' }, surfaces: %w[cli telegram],
      capabilities:, controls_passed: true, command: 'test/openclaw_mission_controls_test.rb', executor:
    ).run
  end

  def statuses(result)
    result.manifest.fetch('missions').to_h { |mission| [mission.fetch('id'), mission.fetch('status')] }
  end

  def readiness_reasons(directory, result)
    Readiness.evaluate(
      protocol: { 'benchmark_protocol_version' => 'openclaw.v1' }, manifest: result.manifest,
      expected_mission_ids: mission_ids, mission_catalog: catalog, artifact_root_base: directory
    ).reasons
  end

  # ---- control executors ---------------------------------------------------

  def oracle_executor
    lambda do |mission:, run_kind:, **|
      {
        'status' => 'ready',
        'metrics_schema_version' => Runner::METRICS_SCHEMA_VERSION,
        'metrics' => mission.fetch('metrics').to_h { |metric| [metric, 1] },
        'hard_zero' => mission.fetch('hard_zero').to_h { |rule| [rule, 'passed'] },
        'effect_outcomes' => [],
        'surface_executions' => surface_executions(mission),
        'provenance' => { 'run_kind' => run_kind, 'provider' => 'fixture-provider', 'model' => 'fixture-model' }
      }
    end
  end

  def null_executor = ->(**) { { 'status' => 'blocked' } }

  # Claims success but reports no evidence — the echo agent.
  def cheap_executor = ->(**) { { 'status' => 'ready', 'metrics' => {} } }

  # Claims success but every hard-zero it was measured against failed.
  def adversary_executor
    lambda do |mission:, run_kind:, **|
      {
        'status' => 'ready',
        'metrics_schema_version' => Runner::METRICS_SCHEMA_VERSION,
        'metrics' => mission.fetch('metrics').to_h { |metric| [metric, 1] },
        'hard_zero' => mission.fetch('hard_zero').to_h { |rule| [rule, 'failed'] },
        'effect_outcomes' => [],
        'surface_executions' => surface_executions(mission),
        'provenance' => { 'run_kind' => run_kind, 'provider' => 'fixture-provider', 'model' => 'fixture-model' }
      }
    end
  end

  # ---- the four verdicts ---------------------------------------------------

  def test_oracle_control_reaches_ready_and_the_gate_finds_no_mission_fault
    Dir.mktmpdir('mission-oracle') do |directory|
      result = run_controls(directory, oracle_executor)

      assert(statuses(result).values.all?('ready'), "oracle must reach ready everywhere: #{statuses(result)}")
      mission_faults = readiness_reasons(directory, result).grep(/\Amission_/)
      assert_empty mission_faults, "the gate must find no mission fault in a clean run: #{mission_faults}"
    end
  end

  def test_null_control_is_blocked_on_every_mission
    Dir.mktmpdir('mission-null') do |directory|
      result = run_controls(directory, null_executor)

      assert_equal mission_ids.to_h { |id| [id, 'blocked'] }, statuses(result)
    end
  end

  def test_cheap_control_is_blocked_on_every_mission
    Dir.mktmpdir('mission-cheap') do |directory|
      result = run_controls(directory, cheap_executor)

      assert_equal mission_ids.to_h { |id| [id, 'blocked'] }, statuses(result)
    end
  end

  def test_adversary_fails_every_mission_and_the_gate_names_the_tripped_hard_zero
    Dir.mktmpdir('mission-adversary') do |directory|
      result = run_controls(directory, adversary_executor)

      assert(statuses(result).values.all?('failed'), "adversary must fail everywhere: #{statuses(result)}")
      reasons = readiness_reasons(directory, result)
      records = result.manifest.fetch('missions').to_h { |mission| [mission.fetch('id'), mission] }
      mission_ids.each do |id|
        assert_includes reasons, "mission_failed:#{id}"
        assert_includes records.fetch(id).fetch('hard_zero').values, 'failed',
                        "the tripped hard-zero must be recorded as the cause for #{id}"
      end
    end
  end
end
