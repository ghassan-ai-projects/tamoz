# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/episode_composition"
require "support/aquaculture_domain"

# T1.3'/T1.4 (PLAN_TAMOZ_STREAM_BUILD): the episode request origin. The wire
# EpisodeRequest is validated (contract, identity, kind, lane, risk ceiling);
# the durable request id embeds (episode_id, attempt_id, fence) so a fence+1
# redispatch is a fresh request and a redelivery is idempotent; the runner
# delivers durably through the durable runner; a tampered snapshot terminates
# before any graph run. P1: the runner-level tests drive the FIXED production
# graph (gate 4 — same graph, in-process driver), not throwaway graphs.
class StreamSituationRequestTest < Minitest::Test
  def worker
    Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def snapshot_pair
    value = {
      "situation_id" => "sit-1",
      "situation_version" => 7,
      "tenant_id" => "acme",
      "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "observed_at" => "2026-08-12T00:00:00Z",
      "spec_digest" => "sha256:#{"d" * 64}",
      "facts" => {"pressure" => 1e-7},
      "event_horizon" => "2026-08-19T00:00:00Z"
    }
    [Tamoz::Core.jcs(value), Tamoz::Core.digest(:snapshot, value)]
  end

  def wire_request(overrides = {})
    snapshot_json, snapshot_sha256 = snapshot_pair
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-1",
      attempt_id: "at-1",
      fence: 1,
      tenant_id: "acme",
      situation_id: "sit-1",
      situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      capability_token: "opaque.hmac.token",
      allowed_intent_types: ["create_maintenance_ticket"],
      intent_catalog_json: Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
      intent_catalog_sha256: AquacultureDomain.intent_catalog_digest,
      supersession_key: "sup-1",
      snapshot_json:,
      snapshot_sha256:,
      **overrides
    )
  end

  def test_the_envelope_validates_and_derives_the_fenced_identity
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(wire_request, worker)

    assert_equal "ep-1", envelope.episode_id
    assert_equal "at-1", envelope.attempt_id
    assert_equal 1, envelope.fence
    assert_equal :diagnose, envelope.kind
    assert_equal "fast", envelope.lane
    assert_equal "r2", envelope.risk_ceiling
    assert_equal "opaque.hmac.token", envelope.capability_token
    assert_equal "episode.ep-1.at-1.1", envelope.request_id
    assert_equal "episode.ep-1", envelope.thread_id
    assert_equal ["acme"], envelope.namespace
    assert_equal "flash", envelope.model_identifier
  end

  def test_watch_confidence_floor_defaults_and_preserves_explicit_zero
    default_envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    assert_equal 0.5, default_envelope.watch_confidence_floor

    opted_out = Tamoz::Stream::EpisodeRequestEnvelope.new(
      wire_request(watch_confidence_floor: 0.0), worker
    )
    assert_equal 0.0, opted_out.watch_confidence_floor
    assert_equal 0.0, opted_out.payload.fetch("episode").fetch("watch_confidence_floor")
  end

  def test_watch_confidence_floor_must_be_finite_and_non_negative
    [-0.1, Float::NAN, Float::INFINITY].each do |floor|
      assert_raises(Tamoz::Stream::StreamError) do
        Tamoz::Stream::EpisodeRequestEnvelope.new(
          wire_request(watch_confidence_floor: floor), worker
        )
      end
    end
  end

  def test_validation_matrix_fails_closed
    cases = {
      protocol: ->(r) { r.protocol_version = "2.0" },
      episode: ->(r) { r.episode_id = "" },
      attempt: ->(r) { r.attempt_id = "" },
      fence_zero: ->(r) { r.fence = 0 },
      kind: ->(r) { r.kind = :EPISODE_KIND_UNSPECIFIED },
      lane: ->(r) { r.lane = :EPISODE_LANE_UNSPECIFIED },
      risk: ->(r) { r.risk_ceiling = :RISK_CLASS_UNSPECIFIED }
    }
    cases.each do |name, mutate|
      request = wire_request
      mutate.call(request)
      assert_raises(Tamoz::Stream::StreamError, "#{name} must fail closed") do
        Tamoz::Stream::EpisodeRequestEnvelope.new(request, worker)
      end
    end
  end

  def test_a_fence_plus_one_redispatch_is_a_fresh_request
    attempt_1 = Tamoz::Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    attempt_2 = Tamoz::Stream::EpisodeRequestEnvelope.new(
      wire_request(fence: 2), worker
    )

    assert_equal "episode.ep-1.at-1.1", attempt_1.request_id
    assert_equal "episode.ep-1.at-1.2", attempt_2.request_id
    refute_equal attempt_1.request_id, attempt_2.request_id
  end

  def request_history(adapter, app)
    app.checkpointer.request_history(thread_id: "episode.ep-1", namespace: ["acme"])
  end

  def with_fixture_endpoint(document: nil)
    Dir.mktmpdir("tamoz-request-endpoint") do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture,
        responses: [Tamoz::Core.jcs(
          document || AquacultureDomain.document(
            selected: "low_dissolved_oxygen", hypothesis: "oxygen crash"
          )
        )],
        log_path: File.join(dir, "endpoint.log")
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def with_durable_app
    with_fixture_endpoint do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      adapter = composition.fetch(:adapter)
      yield adapter, composition.fetch(:app), composition.fetch(:runner)
      adapter.close
    end
  end

  def p1_wire_request(overrides = {})
    EpisodeComposition.wire_request(episode_id: "ep-1", **overrides)
  end

  def runner_with_verification_store(composition, store)
    Tamoz::Stream::EpisodeRunner.new(
      durable_runner: composition.fetch(:app).durable_runner,
      worker: worker,
      verification_store: store
    )
  end

  def test_produced_consequential_intent_opens_an_awaiting_verification
    with_fixture_endpoint do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      store = composition.fetch(:adapter).bind_verification_store
      runner = runner_with_verification_store(composition, store)
      request = p1_wire_request(
        episode_id: "ep-verification",
        allowed_intent_types: ["install_watch_condition", "start_aerator"]
      )

      events = runner.run(request).to_a

      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
      decision_event = events.find { |event| event.decision != nil }
      decision = JSON.parse(decision_event.decision.decision_json)
      intent = decision.fetch("intents").fetch(0)
      assert_equal "R1", intent.fetch("risk_class")

      rows = store.all
      assert_equal 1, rows.length
      row = rows.fetch(0)
      assert_equal :awaiting, row.state
      assert_equal "acme", row.tenant_id
      assert_equal intent.fetch("intent_id"), row.intent_id
      assert_equal decision.fetch("decision_id"), row.decision_id
      assert_equal(
        {
          "tenant" => "acme",
          "user" => "stream",
          "project" => "stream",
          "situation_type" => "aquaculture",
          "entity_type" => "pond",
          "entity_id" => "pond-07"
        },
        row.episode.fetch("scopes")
      )
    ensure
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end

  def test_produced_r0_only_decision_opens_no_verification
    document = AquacultureDomain.document(
      selected: "low_dissolved_oxygen", hypothesis: "oxygen crash"
    ).reject { |key, _| key == "recommended_intents" }
    with_fixture_endpoint(document:) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      store = composition.fetch(:adapter).bind_verification_store
      runner = runner_with_verification_store(composition, store)
      request = p1_wire_request(
        episode_id: "ep-watch-only",
        allowed_intent_types: ["install_watch_condition"]
      )

      events = runner.run(request).to_a

      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
      decision_event = events.find { |event| event.decision != nil }
      decision = JSON.parse(decision_event.decision.decision_json)
      assert_equal ["R0"], decision.fetch("intents").map { |intent| intent.fetch("risk_class") }
      assert_empty store.all
    ensure
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end

  def test_the_runner_delivers_durably_and_redelivery_is_idempotent
    with_durable_app do |adapter, app, runner|
      events = runner.run(p1_wire_request).to_a

      refute_empty events
      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status

      state = app.state(thread: "episode.ep-1", namespace: ["acme"]).state
      assert_kind_of Hash, state[:decision]

      redelivered = runner.run(p1_wire_request).to_a
      assert_equal :TERMINAL_STATUS_PRODUCED, redelivered.last.terminal.status

      history = request_history(adapter, app)
      assert_equal 1, history.length,
                   "redelivery must not enqueue a duplicate request"
      assert_equal :completed, history.first.status
    end
  end

  def test_a_fence_plus_one_redispatch_executes_freshly
    with_durable_app do |_adapter, _app, runner|
      attempt_1 = runner.run(p1_wire_request).to_a
      attempt_2 = runner.run(p1_wire_request(fence: 2)).to_a

      assert_equal :TERMINAL_STATUS_PRODUCED, attempt_1.last.terminal.status
      assert_equal :TERMINAL_STATUS_PRODUCED, attempt_2.last.terminal.status
      assert_equal 1, attempt_1.first.sequence
      assert_equal 1, attempt_2.first.sequence
    end
  end

  # P1: RECONSIDER is out of scope for the fixed diagnose graph — it must
  # terminate typed at admission, never flow into the diagnose path.
  def test_reconsider_episode_terminates_typed
    with_durable_app do |_adapter, _app, runner|
      events = runner.run(
        p1_wire_request(kind: :EPISODE_KIND_RECONSIDER)
      ).to_a
      assert_equal :TERMINAL_STATUS_FAILED, events.last.terminal.status
    end
  end

  def test_a_tampered_snapshot_terminates_before_any_graph_run
    with_durable_app do |adapter, app, runner|
      tampered = p1_wire_request
      tampered.snapshot_json = tampered.snapshot_json.sub("sit-do-crash", "sit-9")

      events = runner.run(tampered).to_a
      assert_equal :TERMINAL_STATUS_FAILED, events.last.terminal.status
      refute events.any? { |event| event.model_started != nil },
             "no model call may run for a tampered snapshot"
      history = request_history(adapter, app)
      assert_empty history, "no request may be enqueued for a tampered snapshot"
    end
  end
end
