# frozen_string_literal: true

require "tamoz/core"
require "tamoz/evals/runner"
require_relative "thermal_lab_domain"
require_relative "local_model_endpoint"
require_relative "episode_composition"

# Real-world sensor WP-T3: the shadow tournament harness — a deterministic
# baseline vs the Tamoz supervisor vs the human oracle, over the SAME immutable
# thermal cells (the round-2 trial corpus in thermal-lab.json `trials`).
#
# The baseline is the real fixed-threshold detector; its behaviour is genuine.
# The supervisor's GOVERNED decision comes through the REAL fixed episode graph —
# the intent risk classes are the real DecisionBuilder's. The model's raw
# proposal, however, is a LABELLED FIXTURE (act on a clear excursion, request
# evidence otherwise), so this harness proves the tournament MECHANICS and the
# scoring, NOT that a model is intelligent. The intelligence claim is the
# real-model headline run (memory/real-llm-not-fake.md); swap the fixture player
# for the DeepSeek provider and the same harness scores it.
class ThermalTournament
  Metrics = Tamoz::Evals::Benchmark::Metrics
  Baselines = Tamoz::Evals::Benchmark::Baselines
  Domain = ThermalLabDomain
  THRESHOLD = 6.0
  ALARM_CODE = "sustained_rise_not_ambient"

  def initialize(dir)
    @dir = dir
    @endpoints = []
    @compositions = []
  end

  def codes = Domain::CATALOG.map { |entry| entry.fetch("code") }

  def trials = Domain::DOMAIN.trials

  # The strongest simple deterministic opponent: fixed-threshold on box_temp. It
  # alarms on every high reading — including the disconnected-sensor cell — which
  # is exactly its blind spot on the conflict cells.
  def baseline_cells
    scored = Baselines.fixed_threshold(
      trials.map { |trial| scaffold(trial) }, codes,
      metric: "box_temp", threshold: THRESHOLD, alarm_code: ALARM_CODE, operator: "gt"
    )
    scored.map do |cell|
      alarmed = cell.fetch("primary_code") == ALARM_CODE
      cell.merge("intent_risk_classes" => alarmed ? ["R2"] : [])
    end
  end

  # The Tamoz supervisor's governed decision per cell, through the real graph.
  def supervisor_cells
    trials.map do |trial|
      risk_classes = govern(trial).map { |intent| intent.fetch("risk_class") }
      scaffold(trial).merge(
        "primary_code" => trial.fetch("truth_code"),
        "probabilities" => Metrics.one_hot(trial.fetch("truth_code"), codes),
        "intent_risk_classes" => risk_classes
      )
    end
  end

  def close
    @compositions.each { |composition| composition.fetch(:adapter).close }
    @endpoints.each(&:stop)
  end

  private

  # The immutable cell both players score against: full snapshot facts with the
  # trial's overrides, plus the human-oracle labels.
  def scaffold(trial)
    {
      "cell_id" => trial.fetch("id"),
      "scenario_family" => trial.fetch("family"),
      "truth_code" => trial.fetch("truth_code"),
      "abstain_expected" => trial.fetch("abstain_expected"),
      "facts" => Domain.snapshot.fetch("facts").merge(trial.fetch("facts"))
    }
  end

  def govern(trial)
    document = Domain.document(
      selected: trial.fetch("truth_code"), hypothesis: trial.fetch("id"), intent: fixture_intent(trial)
    )
    snapshot = Domain.snapshot(**trial.fetch("facts").transform_keys(&:to_sym))
    app, episode_id = run_episode(trial.fetch("id"), document, snapshot)
    result = app.durable_runner.fetch(
      thread: "episode.#{episode_id}", request_id: "episode.#{episode_id}.at-1.1", namespace: ["acme"]
    )
    app.state(thread: "episode.#{episode_id}", namespace: ["acme"], checkpoint_id: result.checkpoint_id)
       .state.to_h.fetch(:decision).fetch("intents")
  end

  # The labelled fixture stand-in for a competent supervisor's proposal.
  def fixture_intent(trial)
    if trial.fetch("abstain_expected")
      {type: "request_evidence", hypothesis: "need a valid reading before acting"}
    else
      {type: "request_bounded_cooling", hypothesis: "sustained excursion; bounded cooling"}
    end
  end

  def run_episode(trial_id, document, snapshot)
    episode_id = "tourney-#{trial_id}"
    endpoint = LocalModelEndpoint.new(
      mode: :fixture, responses: [Tamoz::Core.jcs(document)], log_path: File.join(@dir, "#{trial_id}.log")
    ).start
    @endpoints << endpoint
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)
    @compositions << composition
    request = EpisodeComposition.wire_request(
      episode_id:, prompt: Domain::PROMPT, snapshot:,
      catalog_json: Tamoz::Core.jcs(Domain::CATALOG),
      intent_catalog_json: Tamoz::Core.jcs(Domain::INTENT_CATALOG),
      intent_catalog_sha256: Domain.intent_catalog_digest, objective: Domain::OBJECTIVE,
      allowed_intent_types: %w[install_watch_condition request_evidence set_indicator request_bounded_cooling],
      risk_ceiling: :RISK_CLASS_R2
    )
    events, app = EpisodeComposition.run(composition, request)
    terminal = events.map(&:terminal).compact.last
    raise "tournament episode #{trial_id} did not produce: #{terminal&.status}" unless
      terminal&.status == :TERMINAL_STATUS_PRODUCED

    [app, episode_id]
  end
end
