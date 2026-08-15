# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "tamoz/stream/artifact_store"
require "support/local_model_endpoint"
require "support/episode_composition"

# T2.3 (PLAN_TAMOZ_STREAM_BUILD T2.3): the artifact manifest and retention.
# The terminal carries the per-episode manifest (prompt / skill-set /
# tool-catalog / model-policy / contract / memory-record digests), keyed on
# the STREAM's own digests, and the runner retains the named documents so a
# shadow run can resolve them without re-running Tamoz. Retention is bounded.
# P1: the runner runs the FIXED graph (gate 4).
class StreamArtifactManifestTest < Minitest::Test
  class StubSituationRecaller
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def recall(caller:, snapshot:, query:, limit:)
      @calls << {caller:, snapshot:, query:, limit:}
      @result
    end
  end

  MEMORY_DIGEST = "sha256:#{"e" * 64}"

  def with_fixture_endpoint
    Dir.mktmpdir("tamoz-manifest-endpoint") do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture,
        responses: [Tamoz::Core.jcs(
          AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
        )],
        log_path: File.join(dir, "endpoint.log")
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def raw_digest(digest)
    [digest.delete_prefix("sha256:")].pack("H*")
  end

  def test_the_terminal_carries_the_artifact_manifest
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(
      EpisodeComposition.wire_request(episode_id: "ep-art"), nil
    )
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
    store = Tamoz::Stream::ArtifactStore.new
    recaller = StubSituationRecaller.new(
      Tamoz::Stream::SituationRecall::Result.new(
        records: [Tamoz::Stream::SituationRecall::Projection.new(
          statement: "prior pond oxygen increased",
          scopes: {
            tenant: "acme", situation_type: "aquaculture", entity_type: "pond", entity_id: "pond-00"
          },
          provenance: {
            episode_id: "ep-prior", decision_id: "decision-prior",
            command_id: "command-prior", outcome_id: "outcome-prior"
          },
          digest: MEMORY_DIGEST
        )],
        record_digests: [MEMORY_DIGEST]
      )
    )

    tool_catalog = JSON.generate({"tools" => ["evidence.get"]})
    tool_digest = "sha256:#{"a" * 64}"
    schema = JSON.generate({"$schema" => "x"})
    schema_digest = "sha256:#{"b" * 64}"
    objective_digest = "sha256:#{"c" * 64}"
    wire = EpisodeComposition.wire_request(
      episode_id: "ep-art",
      snapshot_sha256: raw_digest(Tamoz::Core.digest(:snapshot, AquacultureDomain.snapshot)),
      tool_catalog_json: tool_catalog, tool_catalog_sha256: raw_digest(tool_digest),
      decision_schema_json: schema, decision_schema_sha256: raw_digest(schema_digest),
      objective_sha256: raw_digest(objective_digest), objective: "diagnose the pond"
    )

    with_fixture_endpoint do |endpoint|
      composition = EpisodeComposition.build(
        endpoint: endpoint.base_url, artifact_store: store,
        situation_recaller: recaller, recall_caller: {tenant: "acme"}
      )
      events = []
      composition.fetch(:runner).run(wire).each { |event| events << event }
      terminal = events.last.terminal
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      decision_event = events.find { |event| event.decision }
      refute_nil decision_event
      assert_equal 32, decision_event.decision.decision_sha256.bytesize
      manifest = terminal.artifact_manifest
      assert_equal "1.0", manifest.contract_version
      assert_equal 32, manifest.tool_catalog_sha256.bytesize
      assert_equal tool_digest, Tamoz::Core.normalize_digest(manifest.tool_catalog_sha256)
      assert_equal MEMORY_DIGEST,
                   Tamoz::Core.normalize_digest(manifest.memory_record_sha256.fetch(0)),
                   "the manifest names the memory records the episode grounded on"
      assert_equal 1, recaller.calls.length

      # The named documents are retained, resolvable by the STREAM's digests —
      # each under ITS OWN digest (the objective under objective_sha256).
      assert_equal tool_catalog, store.resolve(tool_digest).fetch("bytes")
      assert_equal schema, store.resolve(schema_digest).fetch("bytes")
      assert_equal "diagnose the pond", store.resolve(objective_digest).fetch("bytes")
      # P1: the operator-authored prompt is retained under its own digest.
      assert_equal AquacultureDomain::PROMPT,
                   store.resolve(
                     EpisodeComposition.prompt_sha256(AquacultureDomain::PROMPT)
                   ).fetch("bytes")
      composition.fetch(:adapter).close
    end
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
    store.retain(digest: "sha256:#{"1" * 64}", bytes: "a")
    assert_equal 1, store.size
    assert_equal "a", store.resolve("sha256:#{"1" * 64}").fetch("bytes")
  end

  def test_a_digest_collision_with_different_bytes_is_refused
    store = Tamoz::Stream::ArtifactStore.new
    store.retain(digest: "sha256:#{"1" * 64}", bytes: "a")
    assert_raises(Tamoz::Stream::ArtifactStore::ArtifactStoreError) do
      store.retain(digest: "sha256:#{"1" * 64}", bytes: "b")
    end
  end

  def test_retention_requires_a_sha256_digest_and_a_string_document
    store = Tamoz::Stream::ArtifactStore.new
    assert_raises(Tamoz::Stream::ArtifactStore::ArtifactStoreError) do
      store.retain(digest: "not-a-digest", bytes: "a")
    end
    assert_raises(Tamoz::Stream::ArtifactStore::ArtifactStoreError) do
      store.retain(digest: "sha256:#{"1" * 64}", bytes: {"a" => 1})
    end
  end

  def test_retention_accepts_a_raw_wire_digest
    store = Tamoz::Stream::ArtifactStore.new
    digest = "sha256:#{"a" * 64}"
    raw_digest = [digest.delete_prefix("sha256:")].pack("H*")

    retained = store.retain(digest: raw_digest, bytes: "a")

    assert_equal digest, retained.fetch("digest")
    assert_equal "a", store.resolve(raw_digest).fetch("bytes")
  end
end
