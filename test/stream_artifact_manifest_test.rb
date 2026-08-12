# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "tamoz/stream/artifact_store"

# T2.3 (PLAN_TAMOZ_STREAM_BUILD T2.3): the artifact manifest and retention.
# The terminal carries the per-episode manifest (prompt / skill-set /
# tool-catalog / model-policy / contract / memory-record digests), keyed on
# the STREAM's own digests, and the runner retains the named documents so a
# shadow run can resolve them without re-running Tamoz. Retention is bounded.
class StreamArtifactManifestTest < Minitest::Test
  def snapshot
    {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.9}
    }
  end

  def wire_request(overrides = {})
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-art", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      capability_token: "opaque.hmac.token",
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
      **overrides
    )
  end

  def graph
    Tamoz.graph(name: "episode-artifact", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      state :summary, default: nil
      state :facts_used, default: []
      state :memory_record_digests, default: []
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 4, output_tokens: 2}})
        {
          primary_hypothesis: "bearing wear", confidence: 0.9,
          summary: "confirmed", facts_used: [],
          memory_record_digests: ["sha256:#{"m" * 64}"]
        }
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
  end

  def test_the_terminal_carries_the_artifact_manifest
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(wire_request, nil)
    stream = Tamoz::Stream::EpisodeStream.new(envelope, worker_name: "tamoz")
    stream.started
    manifest = Agenticstream::Runtime::V1::ArtifactManifest.new(
      tool_catalog_sha256: "sha256:#{"t" * 64}",
      contract_version: "1.0"
    )
    stream.terminal(:TERMINAL_STATUS_PRODUCED, artifact_manifest: manifest)

    terminal = stream.events.last.terminal
    assert_equal "1.0", terminal.artifact_manifest.contract_version
    assert_equal "sha256:#{"t" * 64}", terminal.artifact_manifest.tool_catalog_sha256
  end

  def test_the_runner_emits_the_manifest_and_retains_the_named_artifacts
    directory = Dir.mktmpdir("tamoz-artifact-e2e")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    store = Tamoz::Stream::ArtifactStore.new
    app = graph.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil, artifact_store: store
    )

    tool_catalog = JSON.generate({"tools" => ["evidence.get"]})
    tool_digest = "sha256:#{"t" * 64}"
    schema = JSON.generate({"$schema" => "x"})
    schema_digest = "sha256:#{"s" * 64}"
    wire = wire_request(
      tool_catalog_json: tool_catalog, tool_catalog_sha256: tool_digest,
      decision_schema_json: schema, decision_schema_sha256: schema_digest,
      prompt_sha256: "sha256:#{"p" * 64}", objective: "diagnose the compressor"
    )

    events = runner.run(wire).each.to_a
    terminal = events.last.terminal
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    manifest = terminal.artifact_manifest
    assert_equal "1.0", manifest.contract_version
    assert_equal tool_digest, manifest.tool_catalog_sha256
    assert_equal "sha256:#{"m" * 64}", manifest.memory_record_sha256.fetch(0),
                 "the manifest names the memory records the episode grounded on"

    # The named documents are retained, resolvable by the STREAM's digests.
    retained = store.resolve(tool_digest)
    assert_equal tool_catalog, retained.fetch("bytes")
    assert_equal schema, store.resolve(schema_digest).fetch("bytes")
    assert_equal "diagnose the compressor", store.resolve("sha256:#{"p" * 64}").fetch("bytes")
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_retention_is_bounded
    store = Tamoz::Stream::ArtifactStore.new(
      max_artifacts: 2, max_total_bytes: 100
    )
    store.retain(digest: "sha256:#{"1" * 64}", bytes: "a" * 10)
    store.retain(digest: "sha256:#{"2" * 64}", bytes: "b" * 10)
    assert_raises(Tamoz::Stream::ArtifactStore::ArtifactStoreError) do
      store.retain(digest: "sha256:#{"3" * 64}", bytes: "c" * 10)
    end

    small = Tamoz::Stream::ArtifactStore.new(max_total_bytes: 15)
    small.retain(digest: "sha256:#{"1" * 64}", bytes: "x" * 10)
    assert_raises(Tamoz::Stream::ArtifactStore::ArtifactStoreError) do
      small.retain(digest: "sha256:#{"2" * 64}", bytes: "y" * 10)
    end
  end

  def test_retention_is_idempotent_per_digest
    store = Tamoz::Stream::ArtifactStore.new
    store.retain(digest: "sha256:#{"1" * 64}", bytes: "a")
    store.retain(digest: "sha256:#{"1" * 64}", bytes: "b")
    assert_equal 1, store.size
    assert_equal "a", store.resolve("sha256:#{"1" * 64}").fetch("bytes")
  end
end
