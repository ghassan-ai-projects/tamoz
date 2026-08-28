# frozen_string_literal: true

require 'digest'
require 'open3'
require 'tamoz/core'
require 'tamoz/evals/runner'
require_relative 'thermal_lab_domain'

# Real-world sensor WP-T5: the single immutable evidence manifest for a thermal
# shadow run. It BINDS — in one JCS-digested document — the code (git commit +
# dirty state), the domain (intent-catalog / snapshot / objective / prompt
# digests), the decision schema, the exact model call (provider + model +
# sampling + a fixture/real label), the baseline set, and the tournament verdict.
# It reuses the frozen scoring FUNCTIONS (Metrics, Comparison) — it does NOT
# invent a parallel scoring system. The verdict is honest: a fixture-labelled run
# can never read as an intelligence result.
module ThermalManifest
  module_function

  Metrics = Tamoz::Evals::Benchmark::Metrics
  Comparison = Tamoz::Evals::Benchmark::Comparison
  Domain = ThermalLabDomain
  MANIFEST_SCHEMA = 'tamoz.thermal-shadow-run/v1'
  MIN_EFFECT = 0.0

  # cells: {baseline:, supervisor:}; model: {provider:, model:, sampling:, label:}.
  def build(cells:, model:, root:)
    baseline = cells.fetch(:baseline)
    supervisor = cells.fetch(:supervisor)
    comparison = paired(baseline, supervisor)
    manifest = {
      'manifest_schema' => MANIFEST_SCHEMA,
      'git' => git_provenance(root),
      'domain' => domain_digests,
      'decision' => {
        'document_protocol' => 'tamoz.episode-diagnosis/v2',
        'decision_domain' => 'situation-runtime/decision/v1'
      },
      'model' => model,
      'baselines' => ['fixed_threshold'],
      'scoring' => scoring(baseline, supervisor, comparison),
      'verdict' => verdict(comparison, model.fetch('label'))
    }
    manifest.merge('content_digest' => "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(manifest))}")
  end

  def domain_digests
    snapshot = Domain.snapshot
    {
      'id' => 'thermal-lab',
      'intent_catalog_digest' => Domain.intent_catalog_digest,
      'snapshot_digest' => Tamoz::Core.digest(:snapshot, snapshot),
      'objective_digest' => Tamoz::Core.digest("situation-runtime/objective/v1\n", { 'text' => Domain::OBJECTIVE }),
      'prompt_digest' => Tamoz::Core.digest("situation-runtime/prompt/v1\n",
                                            { 'version' => '1.0', 'text' => Domain::PROMPT })
    }
  end

  def scoring(baseline_cells, supervisor_cells, comparison)
    {
      'abstention_quality' => {
        'supervisor' => Metrics.abstention_quality(supervisor_cells),
        'baseline' => Metrics.abstention_quality(baseline_cells)
      },
      'counterfactual_regret' => {
        'supervisor' => Metrics.counterfactual_regret(supervisor_cells),
        'baseline' => Metrics.counterfactual_regret(baseline_cells)
      },
      'comparison' => comparison
    }
  end

  def paired(baseline_cells, supervisor_cells)
    correct = ->(cell) { Metrics.abstained?(cell) == (cell.fetch('abstain_expected') == true) ? 1.0 : 0.0 }
    Comparison.new.paired(
      candidate: supervisor_cells, baseline: baseline_cells, cells: supervisor_cells,
      metric: correct, minimum_effect: MIN_EFFECT, seed: 7
    )
  end

  # A fixture run is NEVER a go — the label is the honest guard (mirrors
  # Report#verdict). A real run's verdict is the paired-interval result.
  def verdict(comparison, label)
    return 'inconclusive_fixture_run' unless label == 'real'

    comparison.fetch('meets_minimum_effect') ? 'go' : 'inconclusive'
  end

  def git_provenance(root)
    commit, = Open3.capture2('git', '-C', root.to_s, 'rev-parse', 'HEAD')
    status, = Open3.capture2('git', '-C', root.to_s, 'status', '--porcelain')
    { 'commit' => commit.strip, 'dirty' => !status.strip.empty? }
  end
end
