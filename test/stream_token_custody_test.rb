# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

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
    EpisodeComposition.wire_request(
      episode_id: "ep-custody",
      attempt: 1,
      fence: 1,
      snapshot: AquacultureDomain.snapshot,
      capability_token: TOKEN
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
    endpoint_directory = Dir.mktmpdir("tamoz-custody-endpoint")
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: AquacultureDomain::FIXTURE_RESPONSES,
      log_path: File.join(endpoint_directory, "endpoint.log")
    ).start
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)
    request = EpisodeComposition.wire_request(
      episode_id: "ep-custody-wire",
      snapshot: AquacultureDomain.snapshot,
      capability_token: TOKEN
    )

    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    events.each do |event|
      serialized = event.to_proto.to_s
      refute_includes serialized, TOKEN,
                      "wire event #{event.sequence} must not carry the token"
      refute_includes serialized, "capability_token",
                      "wire event #{event.sequence} must not expose a token key"
    end
  ensure
    endpoint&.stop
    composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(endpoint_directory) if endpoint_directory
    FileUtils.remove_entry(composition.fetch(:directory)) if composition
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
    endpoint_directory = Dir.mktmpdir("tamoz-custody-endpoint")
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: AquacultureDomain::FIXTURE_RESPONSES,
      log_path: File.join(endpoint_directory, "endpoint.log")
    ).start
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)
    request = EpisodeComposition.wire_request(
      episode_id: "ep-custody-state",
      snapshot: AquacultureDomain.snapshot,
      capability_token: TOKEN
    )

    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    refute_empty events
    checkpointer = composition.fetch(:app).checkpointer
    state = checkpointer.open_writer(
      thread_id: "episode.#{request.episode_id}",
      namespace: [request.tenant_id],
      owner_id: "custody-reader",
      ttl: checkpointer.writer_ttl
    ) { |writer| writer.latest.state.to_h }
    serialized = JSON.generate(state)
    refute_includes serialized, TOKEN,
                    "the durable checkpoint must not carry the capability token"
    refute_includes serialized, "capability_token"
  ensure
    endpoint&.stop
    composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(endpoint_directory) if endpoint_directory
    FileUtils.remove_entry(composition.fetch(:directory)) if composition
  end
end
