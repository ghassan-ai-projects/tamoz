# frozen_string_literal: true

require_relative 'test_helper'
require 'digest'

# Phase B0 (documentation/benchmark/openclaw-chat-study/03-implementation-plan.md):
# the nine canonical comms scenarios run through the composition harness as a
# fixture run — real Normalizer → Gateway admit → SQLite store → Worker drain →
# DeliveryDrainer receipts over a fake scripted transport and a deterministic
# provider — and score deterministically. The same inputs twice must produce
# byte-identical scores. No provider, no real transport, no claim.
class BenchmarkCommsB0Test < Minitest::Test
  Runner = Tamoz::Evals::Benchmark::OpenclawCommsRunner
  Adapter = Tamoz::Evals::Benchmark::OpenclawCommsAdapter
  IndexPath = Pathname.new(ROOT).join('documentation/benchmark/openclaw-chat-study/scenarios/SCENARIO_INDEX.json')

  def with_runner(**options)
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      runner = Runner.new(
        artifact_base: directory, artifact_root: 'fixtures/scenarios',
        git_revision: 'test-revision', command: 'test',
        scenario_index_path: IndexPath, external_adapter: Adapter.new, **options
      )
      yield runner, directory
    end
  end

  def test_runner_requires_an_explicit_external_adapter
    assert_raises(ArgumentError) do
      Runner.new(
        artifact_base: Dir.tmpdir, artifact_root: 'fixtures/scenarios',
        git_revision: 'test-revision', command: 'test', scenario_index_path: IndexPath
      )
    end
  end

  def scores(runner)
    result = runner.run
    result.artifacts.to_h { |artifact| [artifact.fetch('scenario_id'), artifact.fetch('record')] }
  end

  def with_record(scenario)
    with_runner(scenarios: [scenario]) do |runner, directory|
      yield scores(runner).fetch(scenario), directory
    end
  end

  def assert_ready_with(record, metrics)
    actual = metrics.to_h { |name, _| [name, record.dig('metrics', name)] }

    assert_equal({ 'status' => 'ready' }.merge(metrics), { 'status' => record.fetch('status') }.merge(actual),
                 record['reason'])
  end

  def core_facts_compared(parity)
    parity.fetch('compared').slice(*CoreParityFacts)
  end

  def test_pairing_first_contact_and_controls_score_end_to_end
    with_record('C5') do |record, _|
      assert_ready_with record, 'command_parity' => 1, 'inbound_identity' => 1, 'authority_stability' => 1
      assert_equal 'passed', record.dig('hard_zero', 'phantom_command'),
                   'every registry command, the six controls included, must answer a real outcome'
    end
  end

  def test_slow_request_scores_end_to_end
    with_record('C2') do |record, _|
      assert_ready_with record, 'context_inclusion' => 1
      assert_equal 'passed', record.dig('hard_zero', 'unconfirmed_output_in_history')
    end
  end

  def test_truthful_history_scores_end_to_end
    with_record('C1') do |record, _|
      assert_ready_with record, 'admitted' => 1, 'reference_stability' => 1, 'completion' => 1, 'delivery_axis' => 1,
                                'context_inclusion' => 1
    end
  end

  def test_c1_cross_surface_parity_compares_meaning_not_bytes
    with_record('C1') do |record, _|
      parity = record.fetch('parity')

      assert_ready_with record, 'parity' => 1
      assert_equal({ 'status' => 'scored', 'score' => 1 }, parity.slice('status', 'score'))
      assert_equal CoreParityFacts.to_h { |fact| [fact, 1] }, core_facts_compared(parity),
                   'C1 core facts must be compared and equal'
    end
  end

  def test_c1_cross_surface_parity_names_its_unavailable_edges
    with_record('C1') do |record, _|
      edges = record.fetch('parity').fetch('edges')

      assert_includes edges.map { |edge| edge['fact'] }, 'conversation_scoped_cli_reference'
      assert_equal [['unavailable', String]], edges.map { |edge|
        [edge.fetch('status'), edge.fetch('reason').class]
      }.uniq
    end
  end

  def test_c5_controls_subset_parity_covers_status_and_cancel_only
    with_record('C5') do |record, _|
      parity = record.fetch('parity')
      facts = parity.fetch('edges').map { |edge| edge.fetch('fact') }

      assert_ready_with record, 'parity' => 1
      assert_equal({ 'status' => 'scored', 'compared' => { 'status_semantics' => 1, 'cancel_semantics' => 1 } },
                   parity.slice('status', 'compared'))
      assert_empty %w[command_sweep_breadth pairing_and_admission] - facts
    end
  end

  def test_c6_flips_to_scored_cross_surface_parity_with_typed_unavailable_edges
    with_record('C6') do |record, _|
      parity = record.fetch('parity')

      assert_ready_with record, 'parity' => 1, 'context_inclusion' => 1, 'reference_stability' => 1
      assert_equal 'scored', parity.fetch('status')
      assert_equal CoreParityFacts.to_h { |fact| [fact, 1] }, core_facts_compared(parity),
                   'C6 core facts must be compared and equal'
    end
  end

  def test_c6_proves_parity_by_text_rather_than_assuming_it
    with_record('C6') do |record, _|
      assert record.fetch('parity').fetch('distinct_answer_texts')
      assert_equal({ 'parity_by_text' => 'passed', 'surface_outcome_divergence' => 'passed' },
                   record.fetch('hard_zero').slice('parity_by_text', 'surface_outcome_divergence'))
    end
  end

  def test_c6_cancellation_agrees_across_both_surfaces
    with_record('C6') do |record, _|
      cancellation = record.fetch('parity').fetch('cancellation')
      event = cancellation.fetch('observed').first

      assert_equal 1, cancellation.fetch('score')
      assert_equal({ 'payloads_match' => true, 'terminal_delivered' => true, 'terminal_reason' => 'cancelled_by_user' },
                   event.slice('payloads_match', 'terminal_delivered', 'terminal_reason'))
    end
  end

  def test_c9_isolation_parity_holds_across_both_conversations
    with_record('C9') do |record, _|
      assert_ready_with record, 'isolation' => 1, 'parity' => 1
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
    digests = Array.new(2) do
      with_runner do |runner, directory|
        runner.run
        files = %w[manifest.json C1.json C2.json C3.json C4.json C5.json C6.json C7.json C8.json C9.json]
        files.to_h { |name| [name, Digest::SHA256.file(File.join(directory, 'fixtures/scenarios', name)).hexdigest] }
      end
    end

    assert_equal digests.first, digests.last,
                 'artifact bytes (manifest + parity artifacts) must be identical across two runs'
  end

  SCENARIO_IDS = %w[C1 C2 C3 C4 C5 C6 C7 C8 C9].freeze

  def read_fixture_json(directory, name)
    JSON.parse(File.read(File.join(directory, 'fixtures/scenarios', name)))
  end

  def test_all_nine_catalog_scenarios_score_with_an_empty_pending_seam
    with_runner do |runner, directory|
      result = runner.run
      manifest = read_fixture_json(directory, 'manifest.json')

      assert_equal SCENARIO_IDS, manifest.fetch('scenarios')
      assert_equal [{}, {}], [manifest.fetch('pending_seam'), result.manifest.fetch('pending_seam')],
                   'every catalog scenario is expressible over landed seams; none may stay pending'
      assert_equal result.manifest.fetch('results'), manifest.fetch('results')
    end
  end

  def test_the_manifest_declares_a_no_egress_fixture_run_and_the_surfaces_driven
    with_runner do |runner, directory|
      runner.run
      manifest = read_fixture_json(directory, 'manifest.json')

      assert_equal(
        { 'C1' => %w[cli telegram], 'C2' => %w[telegram], 'C3' => %w[telegram], 'C4' => %w[telegram],
          'C5' => %w[cli telegram], 'C6' => %w[cli telegram], 'C7' => %w[telegram],
          'C8' => %w[telegram], 'C9' => %w[cli telegram] },
        manifest.fetch('surfaces_driven')
      )
      assert_equal ['fixture', true], [manifest.fetch('run_kind'), manifest.fetch('fixture')]
      assert_includes manifest.fetch('transport'), 'no_egress'
    end
  end

  def test_every_scenario_artifact_is_a_ready_fixture_result
    with_runner do |runner, directory|
      runner.run
      manifest = read_fixture_json(directory, 'manifest.json')
      SCENARIO_IDS.each do |scenario|
        artifact = read_fixture_json(directory, "#{scenario}.json")

        assert_equal({ 'run_kind' => 'fixture', 'fixture' => true, 'provider' => Runner.const_get(:PROVIDER),
                       'surfaces_driven' => manifest.dig('surfaces_driven', scenario), 'status' => 'ready' },
                     artifact.slice('run_kind', 'fixture', 'provider', 'surfaces_driven')
                             .merge('status' => artifact.dig('result', 'status')),
                     "#{scenario}: #{artifact.dig('result', 'reason')}")
        refute_nil artifact.fetch('seam_revisions')
      end
    end
  end

  def test_the_c6_artifact_records_scored_cross_surface_parity
    with_runner(scenarios: ['C6']) do |runner, directory|
      runner.run

      assert_equal 'scored', read_fixture_json(directory, 'C6.json').dig('result', 'parity', 'status')
    end
  end

  def c8_result(directory)
    read_fixture_json(directory, 'C8.json').fetch('result')
  end

  def c8_timeline(directory, writer)
    c8_result(directory).fetch('timelines').find { |timeline| timeline.fetch('writer') == writer }
  end

  def test_c8_visible_cancellation_scores_end_to_end_over_durable_facts
    with_record('C8') do |record, _|
      assert_ready_with record, 'cancellation_honesty' => 1, 'restart_safety' => 1
      assert_equal 'unavailable', record.dig('metrics', 'parity', 'status')
      assert_equal({ 'false_stopped_claim' => 'passed', 'race_misresolved' => 'passed',
                     'cancellation_state_lost' => 'passed' },
                   record.fetch('hard_zero').slice('false_stopped_claim', 'race_misresolved',
                                                   'cancellation_state_lost'))
    end
  end

  # Clean stop: requested -> observed -> terminal stopped on a turn that never settled.
  def test_c8_clean_stop_ends_stopped_on_a_turn_that_never_settled
    with_record('C8') do |_, directory|
      assert_equal({ 'state' => 'terminal', 'terminal_word' => 'stopped', 'settled' => false,
                     'requested_present' => true, 'observed_present' => true, 'requested_le_observed' => true },
                   c8_timeline(directory, 'store_seam').slice('state', 'terminal_word', 'settled', 'requested_present',
                                                              'observed_present', 'requested_le_observed'))
    end
  end

  # Raced restart: the settle fact won, so the timeline says completed_before_effect, never stopped.
  def test_c8_raced_restart_ends_completed_before_effect
    with_record('C8') do |_, directory|
      assert_equal({ 'terminal_word' => 'completed_before_effect', 'settled' => true, 'settle_le_observed' => true },
                   c8_timeline(directory, 'engine').slice('terminal_word', 'settled', 'settle_le_observed'))
    end
  end

  def test_c8_wordings_match_their_timelines_and_the_engine_edge_is_named
    with_record('C8') do |_, directory|
      result = c8_result(directory)
      wordings = result.fetch('wordings').to_h { |wording| [wording.fetch('reference'), wording] }
      stopped = wordings.fetch(c8_timeline(directory, 'store_seam').fetch('reference'))
      completed = wordings.fetch(c8_timeline(directory, 'engine').fetch('reference'))

      assert_equal [[true, false], [true, false]],
                   [stopped.values_at('claims_stopped', 'claims_completed_before_effect'),
                    completed.values_at('claims_completed_before_effect', 'claims_stopped')]
      assert_includes result.fetch('edges').map { |edge| edge['fact'] }, 'engine_observed_before_settle'
    end
  end
end
