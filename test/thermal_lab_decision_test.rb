# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'tamoz/stream/episode_worker'
require 'support/local_model_endpoint'
require 'support/thermal_lab_domain'
require 'support/episode_composition'

# Real-world sensor WP-T2: the supervisor's action surface is exactly
# {bounded mode, evidence request, abstain}, risk-governed by the CATALOG.
#
# Each case drives the REAL fixed episode graph (EpisodeComposition) with a
# fixture-labelled document and asserts the GOVERNED decision. Zero new Ruby in
# the builder/graph — the discipline is the existing DecisionBuilder authority
# (B10) applied to the thermal-lab domain DATA. Fixture provider throughout: this
# proves the plumbing invariants, NOT intelligence (that is the shadow tournament,
# WP-T3, on a real model).
class ThermalLabDecisionTest < Minitest::Test
  Domain = ThermalLabDomain

  def setup
    @dir = Dir.mktmpdir('tamoz-thermal')
    @endpoints = []
    @compositions = []
  end

  def teardown
    @compositions.each { |c| c.fetch(:adapter).close }
    @endpoints.each(&:stop)
    FileUtils.remove_entry(@dir) if @dir
  end

  # Runs ONE thermal episode whose single model call returns `document`.
  # Returns [terminal, decision_or_nil].
  def run_episode(episode_id:, document:, allowed:, risk_ceiling:, snapshot: Domain.snapshot)
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: [Tamoz::Core.jcs(document)],
      log_path: File.join(@dir, "#{episode_id}.log")
    ).start
    @endpoints << endpoint
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)
    @compositions << composition
    request = EpisodeComposition.wire_request(
      episode_id:, prompt: Domain::PROMPT, snapshot:,
      catalog_json: Tamoz::Core.jcs(Domain::CATALOG),
      intent_catalog_json: Tamoz::Core.jcs(Domain::INTENT_CATALOG),
      intent_catalog_sha256: Domain.intent_catalog_digest,
      objective: Domain::OBJECTIVE,
      allowed_intent_types: allowed, risk_ceiling:
    )
    events, app = EpisodeComposition.run(composition, request)
    terminal = events.filter_map(&:terminal).last
    [terminal, decision_for(app, episode_id, terminal)]
  end

  def decision_for(app, episode_id, terminal)
    return nil unless terminal&.status == :TERMINAL_STATUS_PRODUCED

    result = app.durable_runner.fetch(
      thread: "episode.#{episode_id}",
      request_id: "episode.#{episode_id}.at-1.1",
      namespace: ['acme']
    )
    app.state(thread: "episode.#{episode_id}", namespace: ['acme'], checkpoint_id: result.checkpoint_id)
       .state.to_h.fetch(:decision)
  end

  def sole_intent(decision)
    intents = decision.fetch('intents')

    assert_equal 1, intents.length, 'a DIAGNOSE decision carries exactly one intent'
    intents.fetch(0)
  end

  def catalog_risk(type)
    Tamoz::Agent::IntentCatalog.from_list(Domain::INTENT_CATALOG).risk_for(type)
  end

  # A well-evidenced sustained excursion, with cooling allowed and the R2
  # ceiling, yields the bounded-cooling mode at the CATALOG's risk — still gated
  # for approval downstream (this decision does not dispatch).
  def test_confident_excursion_proposes_bounded_cooling_at_catalog_risk
    terminal, decision = run_episode(
      episode_id: 'thermal-cooling',
      document: Domain.document(
        selected: 'sustained_rise_not_ambient', hypothesis: 'sustained rise, low ambient, no door',
        intent: { type: 'request_bounded_cooling', hypothesis: 'bounded cooling' }
      ),
      allowed: %w[install_watch_condition request_evidence set_indicator request_bounded_cooling],
      risk_ceiling: :RISK_CLASS_R2
    )

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = sole_intent(decision)

    assert_equal 'request_bounded_cooling', intent.fetch('type')
    assert_equal catalog_risk('request_bounded_cooling'), intent.fetch('risk_class'),
                 "risk is the catalog's R2, never the model's (B10)"
  end

  # An explicit evidence request (R0) is a first-class outcome, distinct from the
  # watch fallback — it survives as request_evidence, not a silent demotion.
  def test_evidence_request_is_a_first_class_r0_outcome
    _terminal, decision = run_episode(
      episode_id: 'thermal-evidence',
      document: Domain.document(
        selected: 'sensor_disconnected', hypothesis: 'box_temp sensor disconnected; no usable reading',
        intent: { type: 'request_evidence', hypothesis: 'need a valid box_temp' }
      ),
      snapshot: Domain.snapshot(box_temp_quality: 'disconnected'),
      allowed: %w[install_watch_condition request_evidence set_indicator request_bounded_cooling],
      risk_ceiling: :RISK_CLASS_R2
    )
    intent = sole_intent(decision)

    assert_equal 'request_evidence', intent.fetch('type')
    assert_equal 'R0', intent.fetch('risk_class')
  end

  # No actionable proposal (the model asked only to observe) abstains to the
  # catalog's R0 watch condition.
  def test_already_corrected_abstains_to_watch
    _terminal, decision = run_episode(
      episode_id: 'thermal-abstain',
      document: Domain.document(
        selected: 'already_corrected', hypothesis: 'excursion already corrected; box returning to setpoint',
        intent: { type: 'install_watch_condition', hypothesis: 'observe recovery' }
      ),
      snapshot: Domain.snapshot(corrected_recent: true),
      allowed: %w[install_watch_condition request_evidence set_indicator request_bounded_cooling],
      risk_ceiling: :RISK_CLASS_R2
    )
    intent = sole_intent(decision)

    assert_equal 'install_watch_condition', intent.fetch('type')
    assert_equal 'R0', intent.fetch('risk_class')
  end

  # A cooling proposal that is OFF the operator's allowlist FAILS THE EPISODE
  # CLOSED at the frame gate (validate_recommended_intent_types!) — stronger than
  # a demotion: no decision is produced at all, so no action can leak. The plan
  # assumed a demote-to-watch here; the implemented behaviour is the safer
  # fail-closed, and this test pins that reality.
  def test_off_allowlist_cooling_fails_closed
    terminal, = run_episode(
      episode_id: 'thermal-offallow',
      document: Domain.document(
        selected: 'sustained_rise_not_ambient', hypothesis: 'sustained rise',
        intent: { type: 'request_bounded_cooling', hypothesis: 'cool' }
      ),
      allowed: %w[install_watch_condition request_evidence],
      risk_ceiling: :RISK_CLASS_R2
    )

    assert_equal :TERMINAL_STATUS_FAILED, terminal.status,
                 'an off-allowlist cooling proposal must not produce a decision'
  end

  # A cooling proposal ABOVE the episode's risk ceiling demotes to watch.
  def test_above_ceiling_cooling_demotes_to_watch
    _terminal, decision = run_episode(
      episode_id: 'thermal-ceiling',
      document: Domain.document(
        selected: 'sustained_rise_not_ambient', hypothesis: 'sustained rise',
        intent: { type: 'request_bounded_cooling', hypothesis: 'cool' }
      ),
      allowed: %w[install_watch_condition request_evidence set_indicator request_bounded_cooling],
      risk_ceiling: :RISK_CLASS_R1
    )
    intent = sole_intent(decision)

    assert_equal 'install_watch_condition', intent.fetch('type'),
                 'a proposal above the risk ceiling demotes to watch, never escalates'
    # The model's risk claim never escalates past the ceiling: the demotion lands
    # at the R0 watch, not the proposal's R2 (B10).
    assert_equal 'R0', intent.fetch('risk_class')
  end
end
