# frozen_string_literal: true

require_relative "test_helper"

class EvalsVerifierTest < Minitest::Test
  GOLDEN_ROOT = GEM_ROOTS.fetch("tamoz-evals").join("suites", "m0", "golden")
  BASELINE = GEM_ROOTS.fetch("tamoz-evals").join(
    "baselines", "m0", "baseline.result.json"
  )

  def test_all_twelve_golden_cases_are_valid_and_digest_pinned
    cases = GOLDEN_ROOT.glob("*.case.json").sort

    assert_equal 12, cases.length
    assert_equal 12, cases.map { |path| Tamoz::Evals::Case.load(path).digest }.uniq.length
  end

  def test_fixture_generation_is_reproducible
    Dir.mktmpdir("tamoz-fixture-regeneration") do |directory|
      _stdout, stderr, status = Open3.capture3(
        {"TAMOZ_FIXTURE_ROOT" => directory},
        RbConfig.ruby,
        ROOT.join("script", "generate_m0_fixtures").to_s
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

  def test_reference_cannot_escape_artifact_directory
    Dir.mktmpdir("tamoz-reference-escape") do |directory|
      document = read_json(BASELINE)
      document["references"] = [
        {
          "id" => "escape",
          "kind" => "evidence",
          "path" => "../outside",
          "digest" => "sha256:#{"0" * 64}",
          "classification" => "public"
        }
      ]
      path = File.join(directory, "escape.result.json")
      write_artifact(path, document, domain: "eval.result")

      assert_raises(Tamoz::Evals::ReferenceError) { Tamoz::Evals.verify(path) }
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

  def fixture_files(root)
    root.glob("{baselines,suites}/**/*").select(&:file?).sort
  end
end
