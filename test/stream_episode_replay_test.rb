# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P2 exit gates 1-2: the crash/redispatch matrix and replay with the provider
# network disabled. The journal's LOGICAL keys make a completed tool-loop
# episode replay byte-identically (same parsed document, same decision, same
# tool results) with zero provider calls, and an ambiguous in-flight attempt
# stays typed `unknown` — never a blind retry.
class StreamEpisodeReplayTest < Minitest::Test
  Stream = Tamoz::Stream

  class StubEvidenceTool
    def execute(name, arguments)
      {
        "json" => JSON.generate({"feature" => "dissolved_oxygen", "value" => 1.1}),
        "is_error" => false
      }
    end
  end

  def setup
    @endpoint_dir = Dir.mktmpdir("tamoz-replay")
    @endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: [
        Tamoz::Core.jcs(
          "protocol" => "tamoz.episode-diagnosis/v2",
          "tool_requests" => [{"name" => "evidence.get", "arguments" => {"feature" => "dissolved_oxygen"}}]
        ),
        Tamoz::Core.jcs(
          AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
        )
      ],
      log_path: File.join(@endpoint_dir, "endpoint.log")
    ).start
    @composition = EpisodeComposition.build(
      endpoint: @endpoint.base_url, tool_port: StubEvidenceTool.new
    )
  end

  def teardown
    @endpoint&.stop
    @composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(@endpoint_dir) if @endpoint_dir
  end

  def wire_request(suffix, fence: 1)
    wire = EpisodeComposition.wire_request(episode_id: "replay-#{suffix}", fence:)
    wire.tool_catalog_json = Tamoz::Core.jcs([{"name" => "evidence.get", "parameters" => {}}])
    wire
  end

  def deliver(suffix, fence:)
    request = wire_request(suffix, fence:)
    events = []
    @composition.fetch(:runner).run(request).each { |event| events << event }
    [request, events]
  end

  def terminal_state(suffix, fence:)
    request = wire_request(suffix, fence:)
    result = @composition.fetch(:app).durable_runner.fetch(
      thread: "episode.#{request.episode_id}",
      request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
      namespace: [request.tenant_id]
    )
    @composition.fetch(:app).state(
      thread: "episode.#{request.episode_id}",
      namespace: [request.tenant_id],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
  end

  def test_gate2_completed_tool_loop_replays_with_provider_network_disabled
    _request, events = deliver("replay", fence: 1)
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    assert_equal 2, @endpoint.observed.length, "original run: two provider calls"

    # Kill the provider network entirely, then fence+1 redispatch: the journal
    # returns the completed receipts — no transport call can even be attempted.
    @endpoint.stop
    _request, replayed = deliver("replay", fence: 2)
    assert_equal :TERMINAL_STATUS_PRODUCED, replayed.last.terminal.status
    assert_equal 2, @endpoint.observed.length,
                 "the replayed run made zero new provider calls"

    first = terminal_state("replay", fence: 1)
    second = terminal_state("replay", fence: 2)
    assert_equal first.fetch(:document), second.fetch(:document),
                 "the same parsed document is reconstructed from the journal"
    assert_equal first.fetch(:tool_results), second.fetch(:tool_results),
                 "the same tool results are reconstructed"
    strip_per_run = lambda do |decision|
      JSON.parse(JSON.generate(decision)).tap do |d|
        d.reject! { |k, _| %w[fence attempt_id decision_id valid_until].include?(k) }
        d["intents"] = Array(d["intents"]).map { |i| i.reject { |k, _| k == "expires_at" || k.end_with?("_id", "_digest") } }
      end
    end
    assert_equal strip_per_run.call(first.fetch(:decision)), strip_per_run.call(second.fetch(:decision)),
                 "the same decision is reconstructed"
  end

  def test_gate1_ambiguous_in_flight_attempt_stays_unknown_on_redispatch
    # Step 1: a broken-catalog delivery creates the thread + checkpoint with
    # zero model calls (the base the journal lease checks need).
    broken = wire_request("ambiguous", fence: 1)
    broken.diagnosis_catalog_sha256 = "sha256:#{"0" * 64}"
    @composition.fetch(:runner).run(broken).each { |_event| nil }
    assert_equal 0, @endpoint.observed.length

    # Step 2: seed a started-without-receipt attempt under the SECOND model
    # call's exact logical key (the frame AFTER the deterministic tool result).
    seeded = seed_started_attempt
    assert seeded, "seeding must succeed"

    # Step 3: the full delivery — call 1 (tool turn) is a fresh journaled
    # call; call 2 hits the seeded 'running' attempt → typed unknown.
    _request, events = deliver("ambiguous", fence: 2)
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status,
                 "an ambiguous in-flight attempt terminates typed, never a blind retry"
    assert_equal 1, @endpoint.observed.length,
                 "only call 1 ran; the ambiguous call 2 was never retried with a fresh call"
  end

  private

  # The deterministic tool-result projection the loop's second frame embeds —
  # computed identically by the real EpisodeToolCall + StubEvidenceTool.
  def tool_result_projection
    json = JSON.generate({"feature" => "dissolved_oxygen", "value" => 1.1})
    request_bytes = Tamoz::Core.jcs(
      {"tool" => "evidence.get", "arguments" => {"feature" => "dissolved_oxygen"}}
    )
    {
      "tool" => "evidence.get",
      "request_digest" => "sha256:#{Digest::SHA256.hexdigest(request_bytes)}",
      "result_sha256" => "sha256:#{Digest::SHA256.hexdigest(json)}",
      "is_error" => false,
      "result_bytes" => json.bytesize,
      "slot" => 0,
      "effect_key" => "seeded"
    }
  end

  def seed_started_attempt
    logical = logical_key_for(tool_results: [tool_result_projection])
    store = @composition.fetch(:app).checkpointer
    store.open_writer(
      thread_id: "episode.replay-ambiguous", namespace: ["acme"],
      owner_id: "replay-seeder", ttl: store.writer_ttl
    ) do |writer|
      checkpoint = writer.latest
      return false unless checkpoint

      decision = writer.effects.prepare(
        execution_id: checkpoint.execution_id,
        task_id: "reason",
        call_index: 0,
        operation: "episode.model.reason",
        safety: :unsafe,
        request: {"stage" => "reason", "logical_call_key" => logical.to_key},
        logical_key: logical.to_key
      )
      writer.effects.start(key: decision.record.key, attempt_token: decision.attempt_token)
      true
    end
  end

  def logical_key_for(tool_results: [])
    catalog = Tamoz::Agent::DiagnosisCatalog.from_list(AquacultureDomain::CATALOG)
    snapshot = Tamoz::Core.parse_json_strict(
      Tamoz::Core.jcs(AquacultureDomain.snapshot)
    )
    frame = Tamoz::Agent::EpisodeFrameBuilder.new(
      catalog:, objective: AquacultureDomain::OBJECTIVE
    ).build(
      snapshot:, prompt: AquacultureDomain::PROMPT,
      prompt_version: "1.0", tool_results:
    )
    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: @endpoint.base_url, model: "local-model", provider: "ollama"
    )
    request_bytes = transport.build_request(system: frame.system, prompt: frame.user)
    Tamoz::Agent::ModelCall::LogicalCallKey.new(
      episode_id: "replay-ambiguous", stage: "reason", slot: 0,
      request_digest: transport.request_digest(request_bytes)
    )
  end
end
