# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "net/http"
require "uri"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P3 exit gates 1-2, 4-6: the witness gateway becomes the transport the effect
# adapter calls; its signed records are the evidence (B8 — Tamoz's own events
# stop being evidence). A dummy-request attack (altered frame bytes or an
# ignored response) breaks the binding; a tampered retained byte fails the
# durable verified artifact store; forged receipts are rejected; raw model
# deltas stay off by default. Fixture-labeled throughout.
class StreamEpisodeWitnessTest < Minitest::Test
  Stream = Tamoz::Stream
  SIGNING_KEY = "test-signing-key-0123456789abcdef"

  def setup
    @dir = Dir.mktmpdir("tamoz-witness")
    @provider = LocalModelEndpoint.new(
      mode: :fixture,
      responses: [Tamoz::Core.jcs(
        AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
      )],
      log_path: File.join(@dir, "provider.log")
    ).start
    @gateway = Tamoz::Agent::WitnessGateway.new(
      upstream: @provider.base_url.sub(%r{/v1\z}, ""),
      signing_key: SIGNING_KEY,
      log_path: File.join(@dir, "gateway.log")
    ).start
    @composition = EpisodeComposition.build(
      endpoint: @gateway.base_url,
      gateway: @gateway
    )
  end

  def teardown
    @gateway&.stop
    @provider&.stop
    @composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def test_gate1_gateway_retained_response_reconstructs_the_same_document
    _events, terminal, state = run_episode("witness-1")
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal 1, @gateway.records.length, "one signed gateway record"
    record = @gateway.records.first
    assert @gateway.signature_ok?(record), "the gateway record is properly signed"

    receipt = state.fetch(:model_receipts).first
    # Gate 1: the gateway-retained response reconstructs the same document.
    assert_equal receipt.fetch("request_digest"), record.request_digest
    assert_equal receipt.fetch("response_digest"), record.response_digest
    # The logical call id is the receipt's logical key.
    assert_equal receipt.fetch("effect_id"), record.logical_call_id
    document = state.fetch(:document)
    assert_equal "low_dissolved_oxygen", document.fetch("selected_code")
  end

  def test_gate2_dummy_request_attack_breaks_the_binding
    _events, _terminal, state = run_episode("witness-2")
    receipt = state.fetch(:model_receipts).first
    record = @gateway.records.first

    # Attack 1: altered frame bytes — the receipt claims a different request
    # digest than the gateway signed.
    forged_receipt = receipt.merge("request_digest" => "sha256:#{"f" * 64}")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # Attack 2: an ignored response — the receipt's response digest differs.
    forged_receipt2 = receipt.merge("response_digest" => "sha256:#{"e" * 64}")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt2, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # Attack 3: a forged signature.
    forged_record = Tamoz::Agent::WitnessGateway::Record.new(
      logical_call_id: record.logical_call_id, frame_digest: record.frame_digest,
      request_digest: record.request_digest, response_digest: record.response_digest,
      provider: record.provider, model: record.model,
      provider_request_id: record.provider_request_id,
      settings_digest: record.settings_digest, usage: record.usage,
      signed_at: record.signed_at, signature: "deadbeef"
    )
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt:, gateway_record: forged_record, signing_key: SIGNING_KEY
      )
    end

    # Attack 4: a forged frame digest — the record binds the frame the client
    # asserted; a receipt claiming a different frame fails the binding.
    forged_receipt4 = receipt.merge("frame_digest" => "sha256:#{"d" * 64}")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt4, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # Attack 5: a forged settings digest — the settings are part of the
    # signed binding.
    forged_receipt5 = receipt.merge("settings_digest" => "sha256:#{"c" * 64}")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt5, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # Attack 6: a forged logical call id — the record binds the episode's
    # call identity.
    forged_receipt6 = receipt.merge("effect_id" => "logical:#{"b" * 64}")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt6, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # Attack 7: a forged provider identity.
    forged_receipt7 = receipt.merge("provider" => "evil-gateway")
    assert_raises(Tamoz::Agent::ProtocolError) do
      Tamoz::Agent::WitnessVerifier.verify(
        receipt: forged_receipt7, gateway_record: record, signing_key: SIGNING_KEY
      )
    end

    # The HONEST verification passes — and it recomputes the signature over
    # the record's own payload, never a caller-supplied one.
    Tamoz::Agent::WitnessVerifier.verify(
      receipt:, gateway_record: record, signing_key: SIGNING_KEY
    )
  end

  def test_gate4_tampered_retained_byte_fails_the_verified_store
    checkpointer = @composition.fetch(:app).checkpointer
    adapter = @composition.fetch(:adapter)
    store = adapter.bind_artifact_store(tenant: "acme")
    bytes = "{\"prompt\":\"safe\"}"
    digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    store.retain(digest:, bytes:)

    # Tamper the retained row directly in the database.
    adapter.__send__(:transaction, operation: "artifact.tamper") do |tx|
      tx.execute(
        "artifact.tamper.update",
        "UPDATE tamoz_artifacts SET bytes = ? WHERE tenant_id = ? AND digest = ?",
        ["TAMPERED", "acme", digest]
      )
    end
    assert_raises(Tamoz::SQLite::ArtifactStore::ArtifactStoreError) do
      store.resolve(digest)
    end
  end

  def test_gate5_forged_receipt_without_a_journal_record_is_rejected
    # The forged attack: a receipt projection sits in the terminal state with
    # an effect_key no journal record backs — the checkpoint is node-authored
    # state, the journal is the durable truth, and the runner's B4 emission
    # verification must refuse the projection BEFORE any model event crosses
    # the wire. (The graph can never produce such a receipt on its own — the
    # forged state is the attacker's residue, exercised end to end through the
    # runner's real verification path.)
    _events, _terminal, state = run_episode("witness-forged")
    receipt = state.fetch(:model_receipts).first
    forged = receipt.merge("effect_key" => "logical:#{"0" * 64}")

    error, stream = emit_model_events_through("witness-forged", [forged])
    assert_includes error.message, "wire_refused_model_event"
    assert_empty stream.events.select { |event| event.model_started || event.model_completed },
                 "no forged model event crosses the wire"
  end

  def test_gate6_raw_model_deltas_stay_off_by_default
    # The transport never emits deltas (no delta path exists); the wire has no
    # model_delta events for a completed run.
    events, _terminal, _state = run_episode("witness-6")
    deltas = events.select { |event| event.model_delta != nil }
    assert_empty deltas, "raw model deltas must stay off by default"
  end

  def test_audit_f3_forged_provider_marker_invalidates_the_artifact
    # Audit F3 (B8's stated proof, literal): a receipt carrying a forged
    # provider marker invalidates the stream artifact EVEN with matching
    # journal digests — the design's "provider: test anywhere in a stream
    # artifact invalidates the run". The receipt is journal-backed (its
    # digests verify); only the provider is forged.
    _events, _terminal, state = run_episode("witness-f3")
    receipt = state.fetch(:model_receipts).first
    forged = receipt.merge("provider" => "test")

    error, stream = emit_model_events_through("witness-f3", [forged])
    assert_includes error.message, "wire_refused_model_event/forged_provider_marker",
                    "the forged-marker refusal must be distinguishable from a journal-verification refusal"
    assert_empty stream.events.select { |event| event.model_started || event.model_completed },
                 "no forged-marker model event crosses the wire"
  end

  def test_audit_f3_real_fixture_provider_is_not_discriminated
    # The guard rejects forged markers only — a real fixture receipt carries
    # provider "ollama" + model "local-model" and must still emit (structural
    # separation is the fixture discrimination, not this guard).
    _events, _terminal, state = run_episode("witness-f3-real")
    receipt = state.fetch(:model_receipts).first
    assert_equal "ollama", receipt.fetch("provider")

    error, stream = emit_model_events_through("witness-f3-real", [receipt])
    assert_nil error, "a genuine fixture receipt must emit without refusal"
    refute_empty stream.events.select { |event| event.model_started || event.model_completed },
                 "a genuine fixture receipt must still emit"
  end

  def test_sealed_build_fingerprint_is_deterministic
    a = Tamoz::Agent::SealedBuild.fingerprint(lockfile_path: File.join(@dir, "nonexistent.lock"))
    b = Tamoz::Agent::SealedBuild.fingerprint(lockfile_path: File.join(@dir, "nonexistent.lock"))
    assert_equal a, b, "the sealed build fingerprint is deterministic"
    assert_match(/\Asha256:[0-9a-f]{64}\z/, a)
  end

  def test_gate3_offline_replay_resolves_every_artifact_from_the_verified_store
    adapter = @composition.fetch(:adapter)
    store = adapter.bind_artifact_store(tenant: "acme")
    runner = @composition.fetch(:runner)
    runner.instance_variable_set(:@artifact_store, store)

    _events, terminal, _state = run_episode("synthetic")
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status

    prompt = AquacultureDomain::PROMPT
    refute_nil store.resolve(raw_sha256(prompt)), "the prompt is retained by verified digest"
    catalog_json = Tamoz::Core.jcs(AquacultureDomain::CATALOG)
    refute_nil store.resolve(raw_sha256(catalog_json)), "the catalog is retained"

    result = @composition.fetch(:app).durable_runner.fetch(
      thread: "episode.witness-synthetic",
      request_id: "episode.witness-synthetic.at-1.1",
      namespace: ["acme"]
    )
    state = @composition.fetch(:app).state(
      thread: "episode.witness-synthetic",
      namespace: ["acme"],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
    raw = state.fetch(:raw_response)
    response_digest = "sha256:#{Digest::SHA256.hexdigest(raw)}"
    assert_equal raw, store.resolve(response_digest).fetch("bytes"),
                 "the raw response resolves byte-identical by verified digest"
  end

  def test_sqlite_store_refuses_a_digest_mismatch_on_admission
    adapter = @composition.fetch(:adapter)
    store = adapter.bind_artifact_store(tenant: "acme")
    assert_raises(Tamoz::SQLite::ArtifactStore::ArtifactStoreError) do
      store.retain(digest: "sha256:#{"1" * 64}", bytes: "not-the-bytes")
    end
  end

  def test_sqlite_store_round_trips_binary_bytes_byte_identically
    adapter = @composition.fetch(:adapter)
    store = adapter.bind_artifact_store(tenant: "acme")
    # Wire documents arrive as ASCII-8BIT (binary) strings — the STRICT TEXT
    # column must hold them byte-exact, rehash unchanged. The column tags them
    # UTF-8 on admission; the CONTENT is what the verified digest binds.
    bytes = "\xFF\xFE binary-ish \x00 content".b
    digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    retained = store.retain(digest:, bytes:)
    assert_equal bytes, retained.fetch("bytes").b
    assert_equal bytes, store.resolve(digest).fetch("bytes").b
  end

  def test_gateway_returns_a_typed_400_for_a_bad_envelope
    response = Net::HTTP.post(
      URI(@gateway.base_url),
      JSON.generate({"not" => "an envelope"}),
      "Content-Type" => "application/json"
    )
    assert_equal 400, response.code.to_i
    assert_includes response.body, "witness_gateway/envelope_invalid"
  end

  def test_gateway_returns_a_typed_502_when_the_upstream_is_down
    # A gateway whose upstream port has nothing listening: the forward fails
    # and the gateway answers a typed 502, not a bare connection error.
    probe = TCPServer.new("127.0.0.1", 0)
    dead_port = probe.addr[1]
    probe.close
    dead = Tamoz::Agent::WitnessGateway.new(
      upstream: "http://127.0.0.1:#{dead_port}",
      signing_key: SIGNING_KEY
    ).start
    begin
      response = Net::HTTP.post(
        URI(dead.base_url),
        JSON.generate(
          "logical_call_id" => "logical:deadbeef", "frame_digest" => "sha256:#{"a" * 64}",
          "provider" => "p", "model" => "m", "request_bytes" => "{}"
        ),
        "Content-Type" => "application/json"
      )
      assert_equal 502, response.code.to_i
      assert_includes response.body, "witness_gateway/upstream_failed"
    ensure
      dead.stop
    end
  end

  def test_every_terminal_retains_its_inputs_including_failed_attempts
    # A failed episode (malformed response twice → repair-once then typed
    # FAILED) still retains its inputs: the every-attempt bundle contract.
    dir = Dir.mktmpdir("tamoz-witness-failed")
    provider = LocalModelEndpoint.new(
      mode: :fixture,
      responses: ["not-a-document", "not-a-document"],
      log_path: File.join(dir, "provider.log")
    ).start
    gateway = Tamoz::Agent::WitnessGateway.new(
      upstream: provider.base_url.sub(%r{/v1\z}, ""),
      signing_key: SIGNING_KEY
    ).start
    composition = EpisodeComposition.build(endpoint: gateway.base_url, gateway: gateway)
    adapter = composition.fetch(:adapter)
    store = adapter.bind_artifact_store(tenant: "acme")
    runner = composition.fetch(:runner)
    runner.instance_variable_set(:@artifact_store, store)
    begin
      wire = EpisodeComposition.wire_request(episode_id: "witness-failed")
      events = []
      runner.run(wire).each { |event| events << event }
      terminal = events.map(&:terminal).compact.last
      assert_equal :TERMINAL_STATUS_FAILED, terminal.status
      refute_nil store.resolve(raw_sha256(AquacultureDomain::PROMPT)),
                 "a failed attempt still retains its inputs by verified digest"
      refute_nil store.resolve(raw_sha256(Tamoz::Core.jcs(AquacultureDomain::CATALOG))),
                 "a failed attempt still retains the diagnosis catalog"
    ensure
      composition.fetch(:adapter).close
      gateway.stop
      provider.stop
      FileUtils.remove_entry(dir)
    end
  end

  private

  def raw_sha256(bytes)
    "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  # Shared B4-emission scaffolding: builds the envelope/stream/adapter for an
  # episode and runs emit_model_events over the given receipts. Returns
  # [error_or_nil, stream] so a caller can assert refusal or emission.
  def emit_model_events_through(episode_id, receipts)
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(
      EpisodeComposition.wire_request(episode_id:),
      @composition.fetch(:runner).worker
    )
    stream = Tamoz::Stream::EpisodeStream.new(envelope, worker_name: "tamoz")
    adapter = Tamoz::Stream::EpisodeStreamAdapter.new(stream)
    error = begin
      @composition.fetch(:runner).send(
        :emit_model_events, adapter, {model_receipts: receipts}, envelope
      )
      nil
    rescue Tamoz::Stream::StreamError => caught
      caught
    end
    [error, stream]
  end

  def run_episode(suffix)
    wire = EpisodeComposition.wire_request(episode_id: "witness-#{suffix}")
    events = []
    @composition.fetch(:runner).run(wire).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    state = nil
    if terminal&.status == :TERMINAL_STATUS_PRODUCED
      result = @composition.fetch(:app).durable_runner.fetch(
        thread: "episode.witness-#{suffix}",
        request_id: "episode.witness-#{suffix}.at-1.1",
        namespace: ["acme"]
      )
      state = @composition.fetch(:app).state(
        thread: "episode.witness-#{suffix}",
        namespace: ["acme"],
        checkpoint_id: result.checkpoint_id
      ).state.to_h
    end
    [events, terminal, state]
  end
end
