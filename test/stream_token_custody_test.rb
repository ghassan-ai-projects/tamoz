# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"

# T1.3 (PLAN_TAMOZ_STREAM_BUILD T1.3) — the audit's §4.5 security check: the
# worker holds NO signing secret, only an opaque capability token it carries
# verbatim to the stream's EvidenceTools. This suite pins the custody
# guarantees: the token never lands in the durable payload, never crosses in
# a wire event, never enters the durable request record, and the worker's
# handshake never echoes it.
class StreamTokenCustodyTest < Minitest::Test
  TOKEN = "opaque.hmac.token.7f3c"

  def worker
    Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def snapshot
    {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.2}
    }
  end

  def wire_request
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-custody", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      capability_token: TOKEN,
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot)
    )
  end

  def test_the_token_never_enters_the_durable_payload
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    serialized = JSON.generate(envelope.payload)

    refute_includes serialized, TOKEN,
                    "the durable payload must not carry the capability token"
    assert_empty envelope.payload.fetch("episode").keys.grep(/token/i),
                 "no token-shaped key may cross into the durable payload"
  end

  def test_the_token_never_crosses_in_a_wire_event
    directory = Dir.mktmpdir("tamoz-custody")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    app = Tamoz.graph(name: "episode-custody", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 2, output_tokens: 1}})
        {primary_hypothesis: "x", confidence: 0.9}
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )

    events = runner.run(wire_request).each.to_a
    events.each do |event|
      refute_includes event.to_proto.to_s, TOKEN,
                      "wire event #{event.sequence} must not carry the token"
    end
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_the_handshake_never_echoes_the_token
    response = worker.handshake(
      Agenticstream::Runtime::V1::HandshakeRequest.new(
        protocol_version: "1.0", contract_version: "1.0",
        worker_id: "tamoz", runtime_instance_id: "r1",
        non_interactive: true
      ),
      nil
    )
    assert_equal "tamoz", response.worker_name
    refute_includes response.to_proto.to_s, TOKEN
    refute_includes response.to_proto.to_s, "capability"
  end

  # The audit's §4.5 closing question: the worker holds no signing secret.
  # The episode path carries the token verbatim to EvidenceTools but defines
  # no key material and computes no signature anywhere on the worker. The
  # whole stream gem is scanned (minus the vendored generated stubs), so a
  # new file cannot silently bypass the check.
  def test_the_episode_path_holds_no_signing_secret
    episode_files = ROOT.glob(
      "gems/tamoz-stream/lib/tamoz/stream/*.rb"
    ).reject { |path| path.to_s.include?("/gen/") }
    refute_empty episode_files
    episode_files.each do |path|
      content = File.read(path)
      refute_includes content, "OpenSSL",
                      "#{path} must not reference signing key material"
      refute_includes content, "HMAC",
                      "#{path} must not compute an HMAC (no worker-side mint)"
    end
  end

  # The token never lands in the DURABLE checkpoint state of a full run —
  # the state that survives crashes and redeliveries.
  def test_the_token_never_enters_the_durable_checkpoint_state
    directory = Dir.mktmpdir("tamoz-custody")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    app = Tamoz.graph(name: "episode-custody", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 2, output_tokens: 1}})
        {primary_hypothesis: "x", confidence: 0.9}
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )

    runner.run(wire_request).each.to_a
    checkpoint = app.durable_runner.compiled.checkpointer.latest(
      thread_id: "episode.ep-custody", namespace: ["acme"]
    )
    refute_includes JSON.generate(checkpoint.state.to_h), TOKEN,
                    "the durable checkpoint must not carry the capability token"
    refute_includes JSON.generate(checkpoint.state.to_h), "capability_token"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end
end
