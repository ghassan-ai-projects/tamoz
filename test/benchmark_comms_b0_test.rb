# frozen_string_literal: true

require_relative 'test_helper'
require 'digest'

# Phase B0 (docs/openclaw-chat-study/benchmark-protocol/03-implementation-plan.md):
# the nine canonical comms scenarios run through the composition harness as a
# fixture run — real Normalizer → Gateway admit → SQLite store → Worker drain →
# DeliveryDrainer receipts over a fake scripted transport and a deterministic
# provider — and score deterministically. The same inputs twice must produce
# byte-identical scores. No provider, no real transport, no claim.
class BenchmarkCommsB0Test < Minitest::Test
  Runner = Tamoz::Evals::Benchmark::OpenclawCommsRunner
  IndexPath = Pathname.new(ROOT).join('docs/openclaw-chat-study/benchmark-protocol/scenarios/SCENARIO_INDEX.json')

  def with_runner(**options)
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      runner = Runner.new(
        artifact_base: directory, artifact_root: 'fixtures/scenarios',
        git_revision: 'test-revision', command: 'test',
        scenario_index_path: IndexPath, **options
      )
      yield runner, directory
    end
  end

  def scores(runner)
    result = runner.run
    result.artifacts.to_h { |artifact| [artifact.fetch('scenario_id'), artifact.fetch('record')] }
  end

  def test_pairing_first_contact_and_controls_score_end_to_end
    with_runner(scenarios: ['C5']) do |runner, _|
      records = scores(runner)

      assert_equal 'ready', records.fetch('C5').fetch('status'), records.fetch('C5')['reason']
      assert_equal 1, records.fetch('C5').dig('metrics', 'command_parity')
      assert_equal 1, records.fetch('C5').dig('metrics', 'inbound_identity')
      assert_equal 1, records.fetch('C5').dig('metrics', 'authority_stability')
    end
  end

  def test_slow_request_liveness_ladder_scores_end_to_end
    with_runner(scenarios: ['C2']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C2')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'liveness')
      assert_equal 1, record.dig('metrics', 'progress_bound')
      assert_equal 1, record.dig('metrics', 'context_inclusion')
      assert_equal 'passed', record.dig('hard_zero', 'fabricated_milestone')
    end
  end

  def test_truthful_history_scores_end_to_end
    with_runner(scenarios: ['C1']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C1')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'admission_before_ack')
      assert_equal 1, record.dig('metrics', 'reference_stability')
      assert_equal 1, record.dig('metrics', 'completion')
      assert_equal 1, record.dig('metrics', 'delivery_axis')
      assert_equal 1, record.dig('metrics', 'context_inclusion')
    end
  end

  def test_c1_cross_surface_parity_compares_meaning_not_bytes
    with_runner(scenarios: ['C1']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C1')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'parity')
      parity = record.fetch('parity')
      assert_equal 'scored', parity.fetch('status')
      assert_equal 1, parity.fetch('score')
      CoreParityFacts.each do |fact|
        assert_equal 1, parity.dig('compared', fact), "C1 #{fact} must be compared and equal"
      end
      edges = parity.fetch('edges')
      assert edges.any? { |edge| edge['fact'] == 'conversation_scoped_cli_reference' }
      edges.each do |edge|
        assert_equal 'unavailable', edge.fetch('status')
        assert_instance_of String, edge.fetch('reason')
      end
    end
  end

  def test_c5_controls_subset_parity_covers_status_and_cancel_only
    with_runner(scenarios: ['C5']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C5')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'parity')
      parity = record.fetch('parity')
      assert_equal 'scored', parity.fetch('status')
      assert_equal({ 'status_semantics' => 1, 'cancel_semantics' => 1 }, parity.fetch('compared'))
      facts = parity.fetch('edges').map { |edge| edge.fetch('fact') }
      assert_includes facts, 'command_sweep_breadth'
      assert_includes facts, 'pairing_and_admission'
    end
  end

  def test_c6_flips_to_scored_cross_surface_parity_with_typed_unavailable_edges
    with_runner(scenarios: ['C6']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C6')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'parity')
      assert_equal 1, record.dig('metrics', 'context_inclusion')
      assert_equal 1, record.dig('metrics', 'reference_stability')
      parity = record.fetch('parity')

      assert_equal 'scored', parity.fetch('status')
      CoreParityFacts.each do |fact|
        assert_equal 1, parity.dig('compared', fact), "C6 #{fact} must be compared and equal"
      end
      # parity_by_text is proven, not assumed: the two surfaces answered with
      # different scripted texts while every meaning-level fact still matched.
      assert parity.fetch('distinct_answer_texts')
      assert_equal 'passed', record.dig('hard_zero', 'parity_by_text')
      assert_equal 'passed', record.dig('hard_zero', 'surface_outcome_divergence')
      cancellation = parity.fetch('cancellation')
      assert_equal 1, cancellation.fetch('score')
      event = cancellation.fetch('observed').first
      assert_equal true, event.fetch('payloads_match')
      assert_equal true, event.fetch('terminal_delivered')
      assert_equal 'cancelled_by_user', event.fetch('terminal_reason')
    end
  end

  def test_c9_isolation_parity_holds_across_both_conversations
    with_runner(scenarios: ['C9']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C9')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'isolation')
      assert_equal 1, record.dig('metrics', 'parity')
      assert_equal 'scored', record.dig('parity', 'status')
    end
  end

  def test_scenarios_without_a_cli_leg_keep_typed_unavailable_parity
    with_runner(scenarios: ['C2']) do |runner, _|
      records = scores(runner)

      assert_equal 'unavailable', records.fetch('C2').dig('metrics', 'parity', 'status')
      assert_nil records.fetch('C2')['parity']
    end
  end

  CoreParityFacts = Tamoz::Evals::Benchmark::OpenclawCommsOracles::CORE_PARITY_FACTS.freeze

  def test_identical_runs_produce_byte_identical_scores
    first = nil
    second = nil
    with_runner do |runner, _|
      first = scores(runner).to_json
    end
    with_runner do |runner, _|
      second = scores(runner).to_json
    end

    assert_equal first, second, 'scores must be deterministic across two identical runs'
  end

  def test_artifacts_are_byte_identical_across_two_runs
    digests = 2.times.map do
      with_runner do |runner, directory|
        runner.run
        files = %w[manifest.json C1.json C2.json C3.json C4.json C5.json C6.json C7.json C8.json C9.json]
        files.to_h { |name| [name, Digest::SHA256.file(File.join(directory, 'fixtures/scenarios', name)).hexdigest] }
      end
    end

    assert_equal digests.first, digests.last,
                 'artifact bytes (manifest + parity artifacts) must be identical across two runs'
  end

  def test_all_nine_catalog_scenarios_score_with_an_empty_pending_seam
    with_runner do |runner, directory|
      result = runner.run
      manifest = JSON.parse(File.read(File.join(directory, 'fixtures/scenarios/manifest.json')))

      assert_equal %w[C1 C2 C3 C4 C5 C6 C7 C8 C9], manifest.fetch('scenarios')
      assert_equal({}, manifest.fetch('pending_seam'),
                   'every catalog scenario is expressible over landed seams; none may stay pending')
      assert_empty result.manifest.fetch('pending_seam').keys
      assert_equal(
        { 'C1' => %w[cli telegram], 'C2' => %w[telegram], 'C3' => %w[telegram], 'C4' => %w[telegram],
          'C5' => %w[cli telegram], 'C6' => %w[cli telegram], 'C7' => %w[telegram],
          'C8' => %w[telegram], 'C9' => %w[cli telegram] },
        manifest.fetch('surfaces_driven')
      )
      assert_equal 'fixture', manifest.fetch('run_kind')
      assert manifest.fetch('fixture')
      assert_includes manifest.fetch('transport'), 'no_egress'
      %w[C1 C2 C3 C4 C5 C6 C7 C8 C9].each do |scenario|
        artifact = JSON.parse(
          File.read(File.join(directory, "fixtures/scenarios/#{scenario}.json"))
        )

        assert_equal 'fixture', artifact.fetch('run_kind')
        assert artifact.fetch('fixture')
        assert_equal Runner.const_get(:PROVIDER), artifact.fetch('provider')
        refute_nil artifact.fetch('seam_revisions')
        assert_equal manifest.dig('surfaces_driven', scenario), artifact.fetch('surfaces_driven')
        assert_equal 'ready', artifact.dig('result', 'status'), "#{scenario}: #{artifact.dig('result', 'reason')}"
      end
      c6 = JSON.parse(File.read(File.join(directory, 'fixtures/scenarios/C6.json')))

      assert_equal 'scored', c6.dig('result', 'parity', 'status')
      assert_equal result.manifest.fetch('results'), manifest.fetch('results')
    end
  end

  def test_c8_visible_cancellation_scores_end_to_end_over_durable_facts
    with_runner(scenarios: ['C8']) do |runner, directory|
      records = scores(runner)
      record = records.fetch('C8')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'cancellation_honesty')
      assert_equal 1, record.dig('metrics', 'restart_safety')
      assert_equal 'unavailable', record.dig('metrics', 'parity', 'status')
      %w[false_stopped_claim race_misresolved cancellation_state_lost].each do |hard_zero|
        assert_equal 'passed', record.dig('hard_zero', hard_zero)
      end

      artifact = JSON.parse(File.read(File.join(directory, 'fixtures/scenarios/C8.json')))
      timelines = artifact.fetch('result').fetch('timelines')
      clean = timelines.find { |timeline| timeline.fetch('writer') == 'store_seam' }
      raced = timelines.find { |timeline| timeline.fetch('writer') == 'engine' }

      # Clean stop: requested -> observed -> terminal stopped on a turn that
      # never settled.
      assert_equal 'terminal', clean.fetch('state')
      assert_equal 'stopped', clean.fetch('terminal_word')
      assert_equal false, clean.fetch('settled')
      assert clean.fetch('requested_present')
      assert clean.fetch('observed_present')
      assert clean.fetch('requested_le_observed')

      # Raced restart: the settle fact won, so the timeline and the real
      # /status rendering both say completed_before_effect — never stopped.
      assert_equal 'completed_before_effect', raced.fetch('terminal_word')
      assert raced.fetch('settled')
      assert raced.fetch('settle_le_observed')

      wordings = artifact.fetch('result').fetch('wordings')
      stopped_wording = wordings.find { |wording| wording.fetch('reference') == clean.fetch('reference') }
      completed_wording = wordings.find { |wording| wording.fetch('reference') == raced.fetch('reference') }

      assert_equal true, stopped_wording.fetch('claims_stopped')
      assert_equal false, stopped_wording.fetch('claims_completed_before_effect')
      assert_equal true, completed_wording.fetch('claims_completed_before_effect')
      assert_equal false, completed_wording.fetch('claims_stopped')

      edges = artifact.fetch('result').fetch('edges')
      assert edges.any? { |edge| edge['fact'] == 'engine_observed_before_settle' }
    end
  end

  def test_readiness_refuses_publication_for_a_fixture_run
    protocol = {
      'graph' => { 'name' => 'comms-b0', 'version' => '1' },
      'protocol_version' => 1,
      'missions' => [],
      'controls' => []
    }
    readiness_module = Tamoz::Evals::Benchmark::Readiness
    manifest = {
      'runner_schema_version' => readiness_module::EVIDENCE_SCHEMA_VERSION,
      'protocol_sha256' => readiness_module.protocol_digest(protocol),
      'run_kind' => 'fixture',
      'provider' => 'fixture:deterministic-scripted',
      'model' => 'scripted-provider',
      'artifact_root' => 'fixtures/scenarios',
      'git_revision' => 'test-revision',
      'config_sha256' => "sha256:#{'a' * 64}",
      'graph' => { 'name' => 'comms-b0', 'version' => '1' },
      'surfaces' => %w[cli telegram],
      'command' => 'script/benchmark_comms_run',
      'capabilities' => {
        'comms_channel' => { 'exists' => true, 'reachable' => true, 'authorized' => true,
                             'attempted' => true, 'effective' => true, 'completed' => true,
                             'verified' => true }
      },
      'controls_passed' => false,
      'missions' => [{
        'id' => 'c1', 'status' => 'blocked',
        'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
        'metrics' => { 'completion' => 1 },
        'hard_zero' => { 'ack_before_admission' => 'passed' },
        'effect_outcomes' => [],
        'surface_executions' => {
          'cli' => { 'status' => 'executed', 'provenance' => { 'surface' => 'cli' } },
          'telegram' => { 'status' => 'executed', 'provenance' => { 'surface' => 'telegram' } }
        }
      }],
      'surface_executions' => {}
    }
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'fixtures/scenarios'))
      readiness = readiness_module.evaluate(
        protocol:, manifest:, expected_mission_ids: %w[c1],
        mission_catalog: {
          'schema_version' => 'openclaw.missions.v1',
          'missions' => [{
            'id' => 'c1', 'goal' => 'answer a short turn',
            'metrics' => %w[completion], 'hard_zero' => %w[ack_before_admission],
            'required_capabilities' => ['comms_channel'], 'surfaces' => %w[cli telegram]
          }]
        },
        artifact_root_base: directory
      )

      refute readiness.publishable?, 'a fixture run must never be publishable'
      assert_includes readiness.reasons, 'fixture_or_fake_provider'
    end
  end
end
