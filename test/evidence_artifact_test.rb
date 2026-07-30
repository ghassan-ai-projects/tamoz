# frozen_string_literal: true

require_relative "test_helper"

class EvidenceArtifactTest < Minitest::Test
  def test_evidence_is_canonical_bounded_and_first_class
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)

      verification = Tamoz::Evals.verify(path)
      evidence = Tamoz::Evals::Evidence.load(path)

      assert_equal "evidence", verification.artifact_type
      assert_equal "pass", verification.decision
      assert_equal "m3.phase1.process", evidence["evidence_id"]
      assert_equal verification.digest, evidence.digest
      assert evidence.frozen?
      assert evidence.to_h.frozen?
      assert_equal 1, verification.references.length
    end
  end

  def test_claims_must_be_unique_and_reference_existing_evidence
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document.fetch("claims") << document.fetch("claims").first.dup
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "duplicate ids"

      document.fetch("claims").pop
      document.dig("claims", 0, "evidence_ids") << "missing.output"
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "cites missing evidence"
    end
  end

  def test_process_summary_and_status_semantics_fail_closed
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document.dig("processes", 0, "stdout")["truncated"] = true
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "truncation flag"

      document = read_json(write_valid_evidence(directory))
      document["status"] = "passed"
      document.dig("claims", 0)["status"] = "unknown"
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "every claim to pass"
    end
  end

  def test_process_termination_reason_relations_fail_closed
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)

      document = read_json(path)
      process = document.fetch("processes").first
      process["timed_out"] = true
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "timed_out and termination reason"

      document = read_json(write_valid_evidence(directory))
      process = document.fetch("processes").first
      process["termination"] = "term"
      process["termination_reason"] = "timeout"
      process["timed_out"] = true
      process["exit_status"] = nil
      process["term_signal"] = "TERM"
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "pass", Tamoz::Evals.verify(path).decision

      process["termination_reason"] = "intervention"
      process["timed_out"] = false
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "intentional SIGKILL"
    end
  end

  def test_process_termination_action_matrix_rejects_contradictions
    cases = [
      [
        {
          "termination" => "term",
          "termination_reason" => "none",
          "exit_status" => nil,
          "term_signal" => "TERM"
        },
        "ordinary process termination"
      ],
      [
        {
          "termination" => "none",
          "termination_reason" => "timeout",
          "timed_out" => true
        },
        "timeout requires a harness termination"
      ],
      [
        {
          "termination" => "none",
          "termination_reason" => "cleanup"
        },
        "cleanup requires a harness termination"
      ],
      [
        {
          "termination" => "kill",
          "termination_reason" => "timeout",
          "timed_out" => true,
          "exit_status" => nil,
          "term_signal" => "TERM"
        },
        "SIGKILL harness termination"
      ]
    ]

    Dir.mktmpdir("tamoz-evidence") do |directory|
      cases.each do |attributes, expected_message|
        path = write_valid_evidence(directory)
        document = read_json(path)
        document.fetch("processes").first.merge!(attributes)
        write_artifact(path, document, domain: "eval.evidence")

        error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
          Tamoz::Evals.verify(path)
        end
        assert_includes error.message, expected_message
      end
    end
  end

  def test_selector_evidence_requires_intentional_intervention
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document["selection"] = {
        "operation" => "request.enqueue",
        "point" => "after_sql",
        "statement" => "insert_request",
        "attempt_class" => "first",
        "iteration_class" => "single",
        "selector_digest" => sha("selector")
      }
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "selector evidence"

      process = document.fetch("processes").first
      process["exit_status"] = nil
      process["term_signal"] = "KILL"
      process["termination"] = "kill"
      process["termination_reason"] = "intervention"
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "pass", Tamoz::Evals.verify(path).decision
    end
  end

  def test_cleanup_termination_cannot_be_successful_evidence
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      process = document.fetch("processes").first
      process["exit_status"] = nil
      process["term_signal"] = "TERM"
      process["termination"] = "term"
      process["termination_reason"] = "cleanup"
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "cannot rely on cleanup"

      document["status"] = "failed"
      document.fetch("claims").first["status"] = "fail"
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "fail", Tamoz::Evals.verify(path).decision
    end
  end

  def test_schema_rejects_unknown_and_unbounded_fields
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document["raw_secret"] = "must not be accepted"
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::SchemaError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "unknown properties"

      document.delete("raw_secret")
      document.dig("measurements", 0)["value"] = 9_007_199_254_740_992
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::SchemaError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "above"

      document = read_json(write_valid_evidence(directory))
      document.fetch("processes").first.delete("termination_reason")
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::SchemaError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "termination_reason"
    end
  end

  def test_public_evidence_requires_sanitization_declaration
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document.dig("content_policy")["classification"] = "public"
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "must declare sanitized"

      document.dig("content_policy")["sanitized"] = true
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "pass", Tamoz::Evals.verify(path).decision
    end
  end

  def test_processes_are_unique_bounded_and_fit_envelope_timing
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)
      document.fetch("processes") << document.fetch("processes").first.dup
      write_artifact(path, document, domain: "eval.evidence")

      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "processes contain duplicate ids"

      document.fetch("processes").pop
      document.dig("processes", 0)["duration_ms"] = 26
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "exceeds evidence envelope"

      document["processes"] = []
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "requires a process record"
    end
  end

  def test_nonpassing_statuses_have_distinct_decisions_and_diagnostics
    Dir.mktmpdir("tamoz-evidence") do |directory|
      path = write_valid_evidence(directory)
      document = read_json(path)

      document["status"] = "failed"
      document.dig("claims", 0)["status"] = "fail"
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "fail", Tamoz::Evals.verify(path).decision

      document["status"] = "invalid"
      document["diagnostics"]["invalid_evidence"] = ["selector digest mismatch"]
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "invalid", Tamoz::Evals.verify(path).decision

      document["status"] = "infrastructure_error"
      document["diagnostics"]["invalid_evidence"] = []
      document["diagnostics"]["infrastructure_errors"] = ["sandbox unavailable"]
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "infrastructure_failure", Tamoz::Evals.verify(path).decision

      document["status"] = "insufficient_evidence"
      document["diagnostics"]["infrastructure_errors"] = []
      document["diagnostics"]["evidence_gaps"] = ["reference runner not executed"]
      document.dig("claims", 0)["status"] = "unknown"
      write_artifact(path, document, domain: "eval.evidence")
      assert_equal "insufficient_evidence", Tamoz::Evals.verify(path).decision

      document["diagnostics"]["invalid_evidence"] = ["cannot mix"]
      write_artifact(path, document, domain: "eval.evidence")
      error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
        Tamoz::Evals.verify(path)
      end
      assert_includes error.message, "cannot mix"
    end
  end

  private

  def write_valid_evidence(directory)
    raw_path = File.join(directory, "stdout.txt")
    File.write(raw_path, "ok\n", encoding: Encoding::UTF_8)
    path = File.join(directory, "phase1.evidence.json")
    document = {
      "artifact_type" => "evidence",
      "format_version" => 1,
      "digest_version" => 1,
      "content_digest" => "pending",
      "content_policy" => {
        "classification" => "internal",
        "capture" => "metadata",
        "sanitized" => false
      },
      "evidence_id" => "m3.phase1.process",
      "case_ref" => {
        "id" => "m3.kill-fault-recovery",
        "version" => 1,
        "digest" => sha("case")
      },
      "kind" => "process",
      "status" => "passed",
      "scenario" => {
        "id" => "phase1.subprocess",
        "version" => "v1",
        "digest" => sha("scenario")
      },
      "selection" => nil,
      "subject" => {
        "id" => "tamoz",
        "version" => "0.1.0.alpha.1",
        "git_revision" => "a" * 40,
        "git_tree" => "b" * 40,
        "dirty" => false,
        "digest" => sha("subject")
      },
      "producer" => {
        "id" => "tamoz.m3.harness",
        "version" => "v1",
        "digest" => sha("producer")
      },
      "environment" => {
        "profile" => "pr",
        "ruby_version" => RUBY_VERSION,
        "platform" => RUBY_PLATFORM,
        "sqlite_version" => SQLite3::SQLITE_VERSION,
        "isolation" => "subprocess",
        "network" => "not_used"
      },
      "processes" => [
        {
          "id" => "subject.1",
          "command" => "phase1.smoke",
          "exit_status" => 0,
          "term_signal" => nil,
          "timed_out" => false,
          "termination" => "none",
          "termination_reason" => "none",
          "duration_ms" => 25,
          "stdout" => stream("ok\n"),
          "stderr" => stream("")
        }
      ],
      "claims" => [
        {
          "id" => "process.completed",
          "status" => "pass",
          "oracle" => "The exact bounded subprocess completed successfully.",
          "evidence_ids" => ["phase1.stdout"]
        }
      ],
      "measurements" => [
        {
          "id" => "process.duration",
          "value" => 25,
          "unit" => "ms"
        }
      ],
      "references" => [
        {
          "id" => "phase1.stdout",
          "kind" => "test-output",
          "path" => File.basename(raw_path),
          "digest" => Tamoz::Evals::CanonicalJSON.file_digest(raw_path),
          "size_bytes" => File.size(raw_path),
          "classification" => "internal"
        }
      ],
      "diagnostics" => {
        "invalid_evidence" => [],
        "evidence_gaps" => [],
        "infrastructure_errors" => []
      },
      "timing" => {
        "started_at" => "2026-07-30T10:00:00.000Z",
        "finished_at" => "2026-07-30T10:00:00.025Z",
        "duration_ms" => 25
      }
    }
    write_artifact(path, document, domain: "eval.evidence")
    path
  end

  def stream(value)
    {
      "bytes" => value.bytesize,
      "captured_bytes" => value.bytesize,
      "truncated" => false,
      "digest" => sha(value)
    }
  end

  def sha(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end
end
