# frozen_string_literal: true

require_relative "test_helper"

class EvalsVerifierTest < Minitest::Test
  GOLDEN_ROOT = GEM_ROOTS.fetch("tamoz-evals").join("suites", "m0", "golden")
  M1_ROOT = GEM_ROOTS.fetch("tamoz-evals").join("suites", "m1", "core")
  M2_ROOT = GEM_ROOTS.fetch("tamoz-evals").join("suites", "m2", "graph")
  AGENT_SMOKE_ROOT = GEM_ROOTS.fetch("tamoz-evals").join("suites", "agent", "smoke")
  BASELINE = GEM_ROOTS.fetch("tamoz-evals").join(
    "baselines", "m0", "baseline.result.json"
  )

  def test_all_twelve_golden_cases_are_valid_and_digest_pinned
    cases = GOLDEN_ROOT.glob("*.case.json").sort

    assert_equal 12, cases.length
    assert_equal 12, cases.map { |path| Tamoz::Evals::Case.load(path).digest }.uniq.length
    cases.each do |path|
      artifact = Tamoz::Evals::Case.load(path)
      refute_equal "protected", artifact["split"]
      assert_equal "public", artifact["content_policy"].fetch("classification")
    end
  end

  def test_fixture_generation_is_reproducible
    Dir.mktmpdir("tamoz-fixture-regeneration") do |directory|
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_m0_fixtures").to_s
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_m2_fixtures").to_s
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_m1_fixtures").to_s
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_agent_smoke_fixtures").to_s
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_agent_memory_fixtures").to_s
      )
      assert status.success?, stderr

      expected_root = GEM_ROOTS.fetch("tamoz-evals")
      expected = fixture_files(expected_root).to_h do |path|
        [path.relative_path_from(expected_root).to_s, path.binread]
      end
      actual_root = Pathname.new(directory)
      actual = fixture_files(actual_root).to_h do |path|
        [path.relative_path_from(actual_root).to_s, path.binread]
      end

      assert_equal expected, actual
    end
  end

  def test_all_four_m1_core_cases_are_public_and_digest_pinned
    cases = M1_ROOT.glob("*.case.json").sort

    assert_equal 4, cases.length
    assert_equal 4, cases.map { |path| Tamoz::Evals::Case.load(path).digest }.uniq.length
    cases.each do |path|
      artifact = Tamoz::Evals::Case.load(path)
      assert_equal "tamoz.m1.core", artifact["suite_id"]
      assert_equal "conformance", artifact["split"]
      assert_equal "public", artifact["content_policy"].fetch("classification")
      assert_equal "ruby-test-selection", artifact["input"].fetch("kind")
    end
  end

  def test_all_six_m2_graph_cases_are_public_and_digest_pinned
    cases = M2_ROOT.glob("*.case.json").sort

    assert_equal 6, cases.length
    assert_equal 6, cases.map { |path| Tamoz::Evals::Case.load(path).digest }.uniq.length
    cases.each do |path|
      artifact = Tamoz::Evals::Case.load(path)
      assert_equal "tamoz.m2.graph", artifact["suite_id"]
      assert_equal "conformance", artifact["split"]
      assert_equal "public", artifact["content_policy"].fetch("classification")
      assert_equal "ruby-test-selection", artifact["input"].fetch("kind")
    end
  end

  def test_all_eighteen_agent_smoke_cases_are_public_verified_and_digest_pinned
    cases = AGENT_SMOKE_ROOT.glob("*.case.json").sort

    assert_equal 18, cases.length
    assert_equal 18, cases.map { |path| Tamoz::Evals::Case.load(path).digest }.uniq.length
    cases.each do |path|
      artifact = Tamoz::Evals::Case.load(path)
      assert_equal "tamoz.agent.smoke", artifact["suite_id"]
      assert_equal "development", artifact["split"]
      assert_equal "public", artifact["content_policy"].fetch("classification")
      assert_equal "tamoz-agent-smoke", artifact["input"].fetch("kind")
      assert_includes %w[in_process subprocess], artifact["environment"].fetch("isolation")
      assert_equal "recorded", artifact["environment"].fetch("network")
    end
  end

  def test_baseline_is_honestly_insufficient_and_verifies_reference
    result = Tamoz::Evals::Result.load(BASELINE)

    assert_equal "insufficient_evidence", result["decision"]
    assert_equal 1, Tamoz::Evals.verify(BASELINE).references.length
  end

  def test_cli_returns_distinct_result_codes
    expected = {
      "passed" => ["pass", Tamoz::Evals::CLI::SUCCESS],
      "failed" => ["fail", Tamoz::Evals::CLI::GATE_FAILURE],
      "invalid" => ["invalid", Tamoz::Evals::CLI::INVALID_EVIDENCE],
      "infrastructure_error" => [
        "infrastructure_failure",
        Tamoz::Evals::CLI::INFRASTRUCTURE_FAILURE
      ],
      "insufficient_evidence" => [
        "insufficient_evidence",
        Tamoz::Evals::CLI::INSUFFICIENT_EVIDENCE
      ]
    }

    Dir.mktmpdir("tamoz-result-codes") do |directory|
      FileUtils.mkdir_p(File.join(directory, "evidence"))
      FileUtils.cp(
        BASELINE.dirname.join("evidence", "baseline-summary.json"),
        File.join(directory, "evidence", "baseline-summary.json")
      )

      expected.each do |status, (decision, exit_code)|
        document = read_json(BASELINE)
        document["status"] = status
        document["decision"] = decision
        document["hard_gates"].first["status"] =
          {"passed" => "pass", "failed" => "fail"}.fetch(status, "unknown")
        document["invalid_evidence"] =
          status == "invalid" ? ["synthetic invalid evidence"] : []
        document["evidence_gaps"] =
          status == "insufficient_evidence" ? ["synthetic evidence gap"] : []
        document["infrastructure_errors"] =
          if status == "infrastructure_error"
            [
              {
                "code" => "synthetic.transport",
                "message_safe" => "Synthetic infrastructure failure.",
                "retryable" => true,
                "attempt_id" => "attempt.1"
              }
            ]
          else
            []
          end
        document["provenance"]["attempts"] =
          if status == "infrastructure_error"
            [
              {
                "id" => "attempt.1",
                "index" => 1,
                "status" => "infrastructure_error",
                "reference_ids" => ["m0.baseline-summary"]
              }
            ]
          else
            []
          end
        path = File.join(directory, "#{status}.result.json")
        write_artifact(path, document, domain: "eval.result")

        out = StringIO.new
        err = StringIO.new
        assert_equal exit_code, Tamoz::Evals::CLI.run(["verify", path], out:, err:)
        assert_empty err.string
      end
    end
  end

  def test_cli_rejects_tampered_digest
    Dir.mktmpdir("tamoz-tampered") do |directory|
      document = read_json(GOLDEN_ROOT.glob("*.case.json").first)
      document["title"] = "Tampered without a new digest"
      path = File.join(directory, "tampered.case.json")
      File.write(path, JSON.generate(document), encoding: Encoding::UTF_8)

      out = StringIO.new
      err = StringIO.new
      code = Tamoz::Evals::CLI.run(["verify", path], out:, err:)

      assert_equal Tamoz::Evals::CLI::INVALID_EVIDENCE, code
      assert_empty out.string
      assert_includes err.string, "content digest mismatch"
    end
  end

  def test_duplicate_json_keys_are_rejected_before_schema_validation
    Dir.mktmpdir("tamoz-duplicate-key") do |directory|
      path = File.join(directory, "duplicate.case.json")
      File.write(path, '{"artifact_type":"case","artifact_type":"result"}', encoding: Encoding::UTF_8)

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "duplicate key"
    end
  end

  def test_escaped_duplicate_json_keys_are_rejected
    Dir.mktmpdir("tamoz-escaped-duplicate") do |directory|
      path = File.join(directory, "duplicate.case.json")
      File.write(path, '{"a":1,"\u0061":2}', encoding: Encoding::UTF_8)

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "duplicate key"
    end
  end

  def test_non_ascii_json_reaches_schema_and_digest_validation
    Dir.mktmpdir("tamoz-unicode") do |directory|
      document = read_json(GOLDEN_ROOT.glob("*.case.json").first)
      document["title"] = "Tamoz café"
      path = File.join(directory, "unicode.case.json")
      write_artifact(path, document, domain: "eval.case")

      assert_equal "verified", Tamoz::Evals.verify(path).decision
    end
  end

  def test_reference_cannot_escape_artifact_directory
    Dir.mktmpdir("tamoz-reference-escape") do |directory|
      document = read_json(BASELINE)
      document["references"] = [
        {
          "id" => "escape",
          "kind" => "evidence",
          "path" => "../outside",
          "digest" => "sha256:#{"0" * 64}",
          "size_bytes" => 0,
          "classification" => "public"
        }
      ]
      path = File.join(directory, "escape.result.json")
      write_artifact(path, document, domain: "eval.result")

      assert_raises(Tamoz::Evals::ReferenceError) { Tamoz::Evals.verify(path) }
    end
  end

  def test_reference_size_and_digest_are_both_verified
    Dir.mktmpdir("tamoz-reference-integrity") do |directory|
      FileUtils.mkdir_p(File.join(directory, "evidence"))
      evidence = File.join(directory, "evidence", "baseline-summary.json")
      File.write(evidence, "{}\n", encoding: Encoding::UTF_8)

      document = read_json(BASELINE)
      document["references"].first["size_bytes"] = 1
      document["references"].first["digest"] = Tamoz::Evals::CanonicalJSON.file_digest(evidence)
      path = File.join(directory, "size.result.json")
      write_artifact(path, document, domain: "eval.result")

      error = assert_raises(Tamoz::Evals::ReferenceError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "size mismatch"

      document["references"].first["size_bytes"] = File.size(evidence)
      document["references"].first["digest"] = "sha256:#{"0" * 64}"
      write_artifact(path, document, domain: "eval.result")
      assert_raises(Tamoz::Evals::DigestError) { Tamoz::Evals.verify(path) }
    end
  end

  def test_reference_symlink_cannot_escape_artifact_directory
    Dir.mktmpdir("tamoz-reference-symlink") do |directory|
      outside = File.join(Dir.tmpdir, "tamoz-outside-#{Process.pid}.json")
      File.write(outside, "{}\n", encoding: Encoding::UTF_8)
      File.symlink(outside, File.join(directory, "escaped.json"))

      document = read_json(BASELINE)
      document["references"] = [
        {
          "id" => "escape",
          "kind" => "evidence",
          "path" => "escaped.json",
          "digest" => Tamoz::Evals::CanonicalJSON.file_digest(outside),
          "size_bytes" => File.size(outside),
          "classification" => "public"
        }
      ]
      document["hard_gates"].first["evidence_ids"] = ["escape"]
      path = File.join(directory, "escape.result.json")
      write_artifact(path, document, domain: "eval.result")

      assert_raises(Tamoz::Evals::ReferenceError) { Tamoz::Evals.verify(path) }
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  def test_schema_rejects_unknown_fields
    Dir.mktmpdir("tamoz-unknown-field") do |directory|
      document = read_json(GOLDEN_ROOT.glob("*.case.json").first)
      document["unreviewed_extension"] = true
      path = File.join(directory, "unknown.case.json")
      write_artifact(path, document, domain: "eval.case")

      error = assert_raises(Tamoz::Evals::SchemaError) { Tamoz::Evals.verify(path) }
      assert_includes error.message, "unknown properties"
    end
  end

  def test_case_rejects_ambiguous_capabilities_and_duplicate_evidence
    Dir.mktmpdir("tamoz-case-semantics") do |directory|
      document = read_json(GOLDEN_ROOT.glob("*.case.json").first)
      document["capabilities"]["prohibited"] << document["capabilities"]["allowed"].first
      document["evidence"]["optional"] << document["evidence"]["required"].first
      path = File.join(directory, "ambiguous.case.json")
      write_artifact(path, document, domain: "eval.case")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_match(/duplicate ids|both allowed and prohibited/, error.message)
    end
  end

  def test_artifact_and_reference_paths_reject_nul_bytes
    assert_raises(Tamoz::Evals::ReferenceError) do
      Tamoz::Evals.verify("artifact\0.json")
    end

    Dir.mktmpdir("tamoz-reference-nul") do |directory|
      document = read_json(GOLDEN_ROOT.glob("*.case.json").first)
      document["references"] = [
        {
          "id" => "nul",
          "kind" => "fixture",
          "path" => "evidence\0.json",
          "digest" => "sha256:#{"0" * 64}",
          "size_bytes" => 0,
          "classification" => "public"
        }
      ]
      path = File.join(directory, "nul.case.json")
      write_artifact(path, document, domain: "eval.case")

      assert_raises(Tamoz::Evals::ReferenceError) { Tamoz::Evals.verify(path) }
    end
  end

  def test_pass_cannot_hide_unknown_gate_or_missing_evidence
    Dir.mktmpdir("tamoz-false-pass") do |directory|
      document = read_json(BASELINE)
      document["references"] = []
      document["status"] = "passed"
      document["decision"] = "pass"
      path = File.join(directory, "false-pass.result.json")
      write_artifact(path, document, domain: "eval.result")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_match(/missing evidence|hard gate/, error.message)
    end
  end

  def test_result_timestamps_and_duration_must_agree
    Dir.mktmpdir("tamoz-timing") do |directory|
      document = read_json(BASELINE)
      document["references"] = []
      document["hard_gates"] = []
      document["invalid_evidence"] = ["timing under test"]
      document["status"] = "invalid"
      document["decision"] = "invalid"
      document["timing"]["finished_at"] = "2026-07-30T00:00:01Z"
      document["timing"]["duration_ms"] = 0
      path = File.join(directory, "timing.result.json")
      write_artifact(path, document, domain: "eval.result")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "duration mismatch"
    end
  end

  def test_verification_result_is_deeply_immutable
    verification = Tamoz::Evals.verify(BASELINE)

    assert verification.frozen?
    assert verification.document.frozen?
    assert verification.document.fetch("subject").frozen?
    assert verification.references.frozen?
    assert verification.references.first.fetch("path").frozen?
    assert_raises(FrozenError) do
      verification.document.fetch("subject")["id"] = "mutated"
    end
  end

  def test_provenance_gate_must_match_decision_authority
    Dir.mktmpdir("tamoz-provenance") do |directory|
      copy_baseline_evidence(directory)
      document = read_json(BASELINE)
      document["decision_authority"]["version"] = "v2"
      path = File.join(directory, "provenance.result.json")
      write_artifact(path, document, domain: "eval.result")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "decision authority"
    end
  end

  def test_infrastructure_error_must_bind_an_infrastructure_attempt
    Dir.mktmpdir("tamoz-infrastructure-attempt") do |directory|
      copy_baseline_evidence(directory)
      document = read_json(BASELINE)
      document["status"] = "infrastructure_error"
      document["decision"] = "infrastructure_failure"
      document["evidence_gaps"] = []
      document["infrastructure_errors"] = [
        {
          "code" => "provider.timeout",
          "message_safe" => "The provider timed out.",
          "retryable" => true,
          "attempt_id" => "attempt.1"
        }
      ]
      document["provenance"]["attempts"] = [
        {
          "id" => "attempt.1",
          "index" => 1,
          "status" => "passed",
          "reference_ids" => []
        }
      ]
      path = File.join(directory, "infrastructure.result.json")
      write_artifact(path, document, domain: "eval.result")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "non-infrastructure attempt"
    end
  end

  def test_cli_usage_and_version_are_stable
    out = StringIO.new
    err = StringIO.new
    assert_equal Tamoz::Evals::CLI::USAGE_ERROR, Tamoz::Evals::CLI.run([], out:, err:)
    assert_includes err.string, "expected"

    out = StringIO.new
    err = StringIO.new
    assert_equal Tamoz::Evals::CLI::SUCCESS,
                 Tamoz::Evals::CLI.run(["--version"], out:, err:)
    assert_equal "#{Tamoz::Evals::VERSION}\n", out.string
    assert_empty err.string
  end

  private

  def copy_baseline_evidence(directory)
    FileUtils.mkdir_p(File.join(directory, "evidence"))
    FileUtils.cp(
      BASELINE.dirname.join("evidence", "baseline-summary.json"),
      File.join(directory, "evidence", "baseline-summary.json")
    )
  end

  def fixture_files(root)
    root.glob("{baselines,suites}/**/*").select(&:file?).sort
  end
end
