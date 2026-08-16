# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tamoz/stream/episode_worker"
require "support/aquaculture_domain"

# P8 (docs/new-design/PHASE_P8_ROLLOUT.md): the Ruby side of the mode matrix.
# (1) The calibration artifact generator is deterministic — the same domains
# and build produce the same artifacts, so the SHA is a stable binding.
# (2) The no-hidden-fallback gate: a FIXTURE-provider worker refuses a
# tamoz-mode or active request, so a production route never gets a canned
# answer.
class P8RolloutTest < Minitest::Test
  GENERATOR = ROOT.join("script", "generate_calibration_artifact")

  def generated_artifacts
    JSON.parse(run_generator)
  end

  def test_calibration_artifacts_are_deterministic_and_bound
    first = generated_artifacts
    second = generated_artifacts
    assert_equal first, second, "the calibration artifacts must regenerate identically"
    assert_equal %w[aquaculture climate], first.fetch("artifacts").map { |entry| entry.fetch("domain") }
    first.fetch("artifacts").each do |entry|
      assert_match(/\Asha256:[0-9a-f]{64}\z/, entry.fetch("artifact_sha256"))
      assert_match(/\Asha256:[0-9a-f]{64}\z/, entry.fetch("prompt_sha256"))
      assert_match(/\Asha256:[0-9a-f]{64}\z/, entry.fetch("diagnosis_catalog_sha256"))
      # The model revision is the GO compiled-spec digest, bound at
      # registration (a Ruby process cannot know it) — the generator emits it
      # empty.
      assert_equal "", entry.fetch("model_revision")
      # The artifact SHA binds the Ruby-verifiable document (domain, profile,
      # prompt, diagnosis catalog, policy): changing any of those changes the
      # artifact identity.
      document = entry.reject { |key, _value| %w[artifact_sha256 model_revision].include?(key) }
      expected = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}"
      assert_equal expected, entry.fetch("artifact_sha256")
    end
  end

  def run_generator(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, GENERATOR.to_s, *args, chdir: ROOT.to_s
    )
    assert status.success?, "calibration artifact generator failed:\n#{stderr}#{stdout}"
    stdout
  end

  # Audit follow-up: the generator's domain input is parameterized — an
  # operator-supplied manifest must bind EXACTLY what the fixture path binds.
  # The primary proof: a manifest round-tripped from the test-domain
  # constants produces byte-identical output (all digests + artifact SHA), so
  # the operator path cannot drift from the calibrated path.
  def test_manifest_round_trip_matches_the_default_path_byte_for_byte
    require "support/aquaculture_domain"
    require "support/climate_domain"
    manifest = {"domains" => [
      {"domain" => "aquaculture", "prompt" => AquacultureDomain::PROMPT,
       "diagnosis_catalog" => AquacultureDomain::CATALOG,
       "intent_catalog" => AquacultureDomain::INTENT_CATALOG},
      {"domain" => "climate", "prompt" => ClimateDomain::PROMPT,
       "diagnosis_catalog" => ClimateDomain::CATALOG,
       "intent_catalog" => ClimateDomain::INTENT_CATALOG}
    ]}
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "domains.json")
      File.write(manifest_path, JSON.generate(manifest), encoding: Encoding::UTF_8)
      assert_equal run_generator, run_generator("--manifest", manifest_path),
                   "the manifest path must bind exactly what the default path binds"
    end
  end

  # Secondary guard: the manifest path is NOT hardcoded to the test domains —
  # a single non-fixture domain generates a well-formed, SHA-bound artifact.
  def test_manifest_accepts_a_non_fixture_domain
    manifest = {"domains" => [
      {"domain" => "greenhouse-prod",
       "prompt" => "Diagnose the climate deviation in one greenhouse zone.",
       "diagnosis_catalog" => [
         {"code" => "overheated", "name" => "Overheated", "evidence" => []},
         {"code" => "unknown", "name" => "Unknown", "evidence" => []}
       ],
       "intent_catalog" => [
         {"type" => "install_watch_condition", "risk_class" => "R0"}
       ]}
    ]}
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "greenhouse.json")
      File.write(manifest_path, JSON.generate(manifest), encoding: Encoding::UTF_8)
      output = JSON.parse(run_generator("--manifest", manifest_path))
      artifacts = output.fetch("artifacts")
      assert_equal ["greenhouse-prod"], artifacts.map { |entry| entry.fetch("domain") }
      entry = artifacts.first
      assert_equal "", entry.fetch("model_revision")
      document = entry.reject { |key, _value| %w[artifact_sha256 model_revision].include?(key) }
      expected = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}"
      assert_equal expected, entry.fetch("artifact_sha256")
    end
  end

  def worker(provider_mode:)
    Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1", provider_mode:
    )
  end

  def request(executor_name: "tamoz", dispatch_policy: :DISPATCH_POLICY_ACTIVE)
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "p8-refusal",
      attempt_id: "at-1",
      fence: 1,
      tenant_id: "acme",
      situation_id: "sit-1",
      situation_version: 1,
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R1,
      executor_name:,
      dispatch_policy:,
      model_policy: "fast"
    )
  end

  def test_fixture_provider_refuses_a_tamoz_active_request
    error = assert_raises(GRPC::FailedPrecondition) do
      worker(provider_mode: :fixture).send(:validate_request!, request)
    end
    assert_match(/no hidden fallback/, error.message)
  end

  def test_fixture_provider_refuses_an_active_request_even_for_native
    error = assert_raises(GRPC::FailedPrecondition) do
      worker(provider_mode: :fixture).send(
        :validate_request!, request(executor_name: "native", dispatch_policy: :DISPATCH_POLICY_ACTIVE)
      )
    end
    assert_match(/no hidden fallback/, error.message)
  end

  def test_fixture_provider_serves_only_native_shadow_requests
    # Shadow demo/test runs are the one mode a fixture may serve — and only
    # under a non-tamoz executor (a tamoz-mode request must hit a real model,
    # period — that is the no-hidden-fallback rule). Nothing from a shadow run
    # enters action governance.
    assert_equal true, worker(provider_mode: :fixture).send(
      :validate_request!,
      request(executor_name: "native", dispatch_policy: :DISPATCH_POLICY_SHADOW)
    )
  end

  def test_fixture_provider_refuses_tamoz_even_for_shadow
    error = assert_raises(GRPC::FailedPrecondition) do
      worker(provider_mode: :fixture).send(
        :validate_request!,
        request(executor_name: "tamoz", dispatch_policy: :DISPATCH_POLICY_SHADOW)
      )
    end
    assert_match(/no hidden fallback/, error.message)
  end

  def test_real_provider_serves_active_requests
    assert_equal true, worker(provider_mode: :real).send(:validate_request!, request)
  end
end
