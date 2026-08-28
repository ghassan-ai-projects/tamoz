# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'support/thermal_tournament'
require 'support/thermal_manifest'

# Real-world sensor WP-T5: the evidence manifest binds a thermal shadow run to
# durable evidence (code + domain + model + verdict) in one immutable document,
# and the parity decision (local path) keeps thermal-lab out of the frozen
# benchmark protocol.
class ThermalManifestTest < Minitest::Test
  PROTOCOL_PATH = ROOT.join('documentation', 'benchmark', 'BENCHMARK_PROTOCOL.json')

  def setup
    @dir = Dir.mktmpdir('tamoz-manifest')
    tourney = ThermalTournament.new(@dir)
    @baseline = tourney.baseline_cells
    @supervisor = tourney.supervisor_cells
    tourney.close
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def build(label: 'fixture', provider: 'tamoz-local', model: 'local-model')
    ThermalManifest.build(
      cells: { baseline: @baseline, supervisor: @supervisor },
      model: { 'provider' => provider, 'model' => model, 'label' => label,
               'sampling' => { 'temperature' => 0, 'response_format' => 'json_object' } },
      root: ROOT
    )
  end

  def test_manifest_binds_the_code_commit
    assert_match(/\A[0-9a-f]{40}\z/, build.dig('git', 'commit'))
  end

  def test_manifest_binds_every_domain_digest
    domain = build.fetch('domain')

    %w[intent_catalog_digest snapshot_digest prompt_digest objective_digest].each do |key|
      assert_match(/\Asha256:/, domain.fetch(key), "#{key} must be a sha256 digest")
    end
  end

  def test_manifest_binds_the_model_call_and_content_digest
    manifest = build

    assert_equal 'local-model', manifest.dig('model', 'model')
    assert_match(/\Asha256:/, manifest.fetch('content_digest'))
  end

  def test_manifest_is_reproducible
    assert_equal build.fetch('content_digest'), build.fetch('content_digest'),
                 'the same run digests identically'
  end

  # The honesty guard: a fixture run can never be a `go`, whatever the numbers.
  def test_a_fixture_run_is_never_a_go
    assert_equal 'inconclusive_fixture_run', build(label: 'fixture').fetch('verdict')
  end

  # The manifest records that the supervisor out-abstains the baseline — the
  # evidence the headline claim would rest on (once a real model produces it).
  def test_scoring_is_recorded
    scoring = build.fetch('scoring')

    assert_operator scoring.dig('abstention_quality', 'supervisor'), :>,
                    scoring.dig('abstention_quality', 'baseline')
    assert_operator scoring.dig('comparison', 'mean_difference'), :>, 0.0
  end

  # Parity, local path (Decision Log #2 default): thermal-lab does NOT enter the
  # frozen protocol, so the six pinned wire digests are untouched.
  def test_thermal_lab_is_absent_from_the_frozen_protocol
    protocol = JSON.parse(File.read(PROTOCOL_PATH))
    domains = protocol.fetch('case_matrix').fetch('domains')

    refute_includes domains, 'thermal-lab',
                    'thermal-lab is tamoz-local; promoting it into the protocol is a separate reviewed change'
  end
end
