# frozen_string_literal: true

require_relative "test_helper"

# T1.3'/T1.4 (PLAN_TAMOZ_STREAM_BUILD): the episode request origin. The wire
# EpisodeRequest is validated (contract, identity, kind, lane, risk ceiling);
# the durable request id embeds (episode_id, attempt_id, fence) so a fence+1
# redispatch is a fresh request and a redelivery is idempotent; the runner
# delivers durably through the durable runner; a tampered snapshot terminates
# before any graph run.
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
      allowed_intent_types: ["maintenance.ticket"],
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

  def episode_graph
    Tamoz.graph(name: "episode-turn", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :ack, default: nil
      node(
        :ack,
        implementation_name: "episode.ack",
        version: "1"
      ) do |state, _context|
        {ack: state.fetch(:episode).fetch("episode_id")}
      end
      edge Tamoz::START, :ack
      edge :ack, Tamoz::END
    end
  end

  def request_history(adapter, app)
    app.checkpointer.request_history(thread_id: "episode.ep-1", namespace: ["acme"])
  end

  def with_durable_app
    Dir.mktmpdir("tamoz-episode-request") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      app = episode_graph.compile(checkpointer: adapter)
      runner = Tamoz::Stream::EpisodeRunner.new(durable_runner: app.durable_runner, worker:)
      yield adapter, app, runner
      adapter.close
    end
  end

  def test_the_runner_delivers_durably_and_redelivery_is_idempotent
    with_durable_app do |adapter, app, runner|
      events = runner.run(wire_request).to_a

      refute_empty events
      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status

      redelivered = runner.run(wire_request).to_a
      assert_equal :TERMINAL_STATUS_PRODUCED, redelivered.last.terminal.status

      history = request_history(adapter, app)
      assert_equal 1, history.length,
                   "redelivery must not enqueue a duplicate request"
      assert_equal :completed, history.first.status
    end
  end

  def test_a_fence_plus_one_redispatch_executes_freshly
    with_durable_app do |_adapter, _app, runner|
      attempt_1 = runner.run(wire_request).to_a
      attempt_2 = runner.run(wire_request(fence: 2)).to_a

      assert_equal :TERMINAL_STATUS_PRODUCED, attempt_1.last.terminal.status
      assert_equal :TERMINAL_STATUS_PRODUCED, attempt_2.last.terminal.status
      assert_equal 1, attempt_1.first.sequence
      assert_equal 1, attempt_2.first.sequence
    end
  end

  def test_a_tampered_snapshot_terminates_before_any_graph_run
    with_durable_app do |adapter, app, runner|
      tampered = wire_request
      tampered.snapshot_json = tampered.snapshot_json.sub("sit-1", "sit-9")

      events = runner.run(tampered).to_a
      assert_equal :TERMINAL_STATUS_FAILED, events.last.terminal.status
      refute events.any? { |event| event.model_started != nil },
             "no model call may run for a tampered snapshot"
      history = request_history(adapter, app)
      assert_empty history, "no request may be enqueued for a tampered snapshot"
    end
  end
end
