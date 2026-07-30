# frozen_string_literal: true

require "json"
require "time"

module Tamoz
  module Evals
    class Verifier
      MAX_ARTIFACT_BYTES = 2 * 1024 * 1024
      MAX_REFERENCE_BYTES = 16 * 1024 * 1024
      MAX_TOTAL_REFERENCE_BYTES = 64 * 1024 * 1024
      DIGEST_DOMAINS = {
        "case" => "eval.case",
        "result" => "eval.result"
      }.freeze
      RESULT_DECISIONS = {
        "passed" => "pass",
        "failed" => "fail",
        "invalid" => "invalid",
        "infrastructure_error" => "infrastructure_failure",
        "insufficient_evidence" => "insufficient_evidence"
      }.freeze

      Verification = Data.define(
        :path,
        :artifact_type,
        :decision,
        :digest,
        :document,
        :references
      )

      def verify(path)
        raw_path = begin
          File.path(path)
        rescue TypeError, ArgumentError => error
          raise ReferenceError, "invalid artifact path: #{error.message}"
        end
        raise ReferenceError, "artifact path contains a NUL byte" if raw_path.include?("\0")

        expanded_path = File.expand_path(raw_path)
        document = read_document(expanded_path)
        artifact_type = document["artifact_type"]
        domain = DIGEST_DOMAINS.fetch(artifact_type) do
          raise UnsupportedFormatError, "unsupported artifact type: #{artifact_type.inspect}"
        end

        Schema.load(artifact_type).validate!(document)
        verify_digest!(document, domain)
        assert_unique_ids!(document.fetch("references"), "references")
        references = verify_references!(document.fetch("references"), expanded_path)
        decision = verify_semantics!(artifact_type, document)

        Verification.new(
          path: expanded_path.freeze,
          artifact_type: artifact_type.freeze,
          decision: decision.freeze,
          digest: document.fetch("content_digest").freeze,
          document: DeepFreeze.call(CanonicalJSON.normalize(document)),
          references: DeepFreeze.call(references)
        ).freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
        raise ReferenceError, "#{expanded_path}: #{error.message}"
      rescue JSON::ParserError => error
        raise InvalidArtifactError, "#{expanded_path}: invalid JSON: #{error.message}"
      end

      private

      def read_document(path)
        bytes = read_stable_file(path, max_bytes: MAX_ARTIFACT_BYTES, kind: "artifact")
        text = bytes.force_encoding(Encoding::UTF_8)
        raise InvalidArtifactError, "#{path}: artifact is not valid UTF-8" unless text.valid_encoding?

        DuplicateKeyDetector.validate!(text)
        JSON.parse(
          text,
          create_additions: false,
          max_nesting: 100
        )
      end

      def verify_digest!(document, domain)
        version = document.fetch("digest_version")
        unless version == CanonicalJSON::DIGEST_VERSION
          raise UnsupportedFormatError, "unsupported digest version: #{version.inspect}"
        end

        expected = CanonicalJSON.content_digest(document, domain: domain)
        actual = document.fetch("content_digest")
        return if actual == expected

        raise DigestError, "content digest mismatch: expected #{expected}, got #{actual}"
      end

      def verify_references!(references, artifact_path)
        root = File.realpath(File.dirname(artifact_path))
        total_bytes = 0

        references.map do |reference|
          relative_path = reference.fetch("path")
          if relative_path.include?("\0") ||
             relative_path.include?("\\") ||
             Pathname.new(relative_path).absolute? ||
             Pathname.new(relative_path).each_filename.include?("..")
            raise ReferenceError, "reference path escapes artifact directory: #{relative_path.inspect}"
          end

          candidate = File.expand_path(relative_path, root)
          real_path = File.realpath(candidate)
          root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
          unless real_path != root && real_path.start_with?(root_prefix)
            raise ReferenceError, "reference resolves outside artifact directory: #{relative_path.inspect}"
          end

          expected_size = reference.fetch("size_bytes")
          bytes = read_stable_file(
            real_path,
            max_bytes: [MAX_REFERENCE_BYTES, MAX_TOTAL_REFERENCE_BYTES - total_bytes].min,
            kind: "reference"
          )
          actual_size = bytes.bytesize
          unless actual_size == expected_size
            raise ReferenceError,
                  "reference size mismatch for #{relative_path}: expected #{expected_size}, " \
                  "got #{actual_size}"
          end
          total_bytes += actual_size

          actual_digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
          expected_digest = reference.fetch("digest")
          unless actual_digest == expected_digest
            raise DigestError,
                  "reference digest mismatch for #{relative_path}: expected #{expected_digest}, " \
                  "got #{actual_digest}"
          end

          {
            "id" => reference.fetch("id"),
            "path" => real_path,
            "digest" => actual_digest,
            "size_bytes" => actual_size
          }
        end
      end

      def verify_semantics!(artifact_type, document)
        if artifact_type == "case"
          verify_case_semantics!(document)
          return "verified"
        end

        expected = RESULT_DECISIONS.fetch(document.fetch("status"))
        actual = document.fetch("decision")
        unless actual == expected
          raise InvalidArtifactError,
                "result status #{document.fetch("status").inspect} requires decision " \
                "#{expected.inspect}, got #{actual.inspect}"
        end

        references = document.fetch("references")
        hard_gates = document.fetch("hard_gates")
        assert_unique_ids!(hard_gates, "hard_gates")
        assert_unique_ids!(document.fetch("scores"), "scores")
        reference_ids = references.map { |reference| reference.fetch("id") }

        hard_gates.each do |gate|
          missing = gate.fetch("evidence_ids") - reference_ids
          unless missing.empty?
            raise InvalidArtifactError,
                  "hard gate #{gate.fetch("id").inspect} cites missing evidence #{missing.inspect}"
          end
        end

        verify_provenance!(document, reference_ids)
        verify_timing!(document.fetch("timing"))
        verify_decision_evidence!(document, hard_gates, references)
        actual
      end

      def verify_case_semantics!(document)
        evidence = document.fetch("evidence")
        evidence_specs = evidence.fetch("required") + evidence.fetch("optional")
        assert_unique_ids!(evidence_specs, "evidence")
        assert_unique_ids!(document.fetch("scorers"), "scorers")

        capabilities = document.fetch("capabilities")
        overlap = capabilities.fetch("allowed") & capabilities.fetch("prohibited")
        unless overlap.empty?
          raise InvalidArtifactError,
                "capabilities cannot be both allowed and prohibited: #{overlap.sort.inspect}"
        end
      end

      def verify_provenance!(document, reference_ids)
        provenance = document.fetch("provenance")
        components = provenance.fetch("components")
        identities = components.map { |component| [component.fetch("role"), component.fetch("id")] }
        duplicates = identities.tally.select { |_identity, count| count > 1 }.keys
        unless duplicates.empty?
          raise InvalidArtifactError, "provenance components contain duplicate role/id pairs"
        end

        %w[evaluator gate].each do |required_role|
          count = components.count { |component| component.fetch("role") == required_role }
          unless count == 1
            raise InvalidArtifactError,
                  "provenance requires exactly one #{required_role} component, got #{count}"
          end
        end

        authority = document.fetch("decision_authority")
        gate = components.find { |component| component.fetch("role") == "gate" }
        unless %w[id version digest].all? { |key| gate.fetch(key) == authority.fetch(key) }
          raise InvalidArtifactError, "decision authority does not match the provenance gate"
        end

        attempts = provenance.fetch("attempts")
        assert_unique_ids!(attempts, "attempts")
        attempt_indexes = attempts.map { |attempt| attempt.fetch("index") }
        unless attempt_indexes.uniq.length == attempt_indexes.length
          raise InvalidArtifactError, "provenance attempts contain duplicate indexes"
        end
        assert_unique_ids!(provenance.fetch("fixtures"), "fixtures")
        snapshot_kinds = provenance.fetch("snapshots").map { |snapshot| snapshot.fetch("kind") }
        unless snapshot_kinds.uniq.length == snapshot_kinds.length
          raise InvalidArtifactError, "provenance snapshots contain duplicate kinds"
        end

        repetition = provenance.fetch("repetition")
        if repetition.fetch("index") > repetition.fetch("count")
          raise InvalidArtifactError, "repetition index exceeds repetition count"
        end

        attempts.each do |attempt|
          missing = attempt.fetch("reference_ids") - reference_ids
          unless missing.empty?
            raise InvalidArtifactError,
                  "attempt #{attempt.fetch("id").inspect} cites missing evidence #{missing.inspect}"
          end
        end

        document.fetch("infrastructure_errors").each do |error|
          attempt = attempts.find { |candidate| candidate.fetch("id") == error.fetch("attempt_id") }
          unless attempt
            raise InvalidArtifactError,
                  "infrastructure error cites missing attempt #{error.fetch("attempt_id").inspect}"
          end
          unless attempt.fetch("status") == "infrastructure_error"
            raise InvalidArtifactError,
                  "infrastructure error cites a non-infrastructure attempt"
          end
        end
      end

      def assert_unique_ids!(records, field)
        ids = records.map { |record| record.fetch("id") }
        duplicates = ids.tally.select { |_id, count| count > 1 }.keys
        return if duplicates.empty?

        raise InvalidArtifactError, "#{field} contain duplicate ids: #{duplicates.sort.inspect}"
      end

      def verify_timing!(timing)
        started_at = Time.iso8601(timing.fetch("started_at"))
        finished_at = Time.iso8601(timing.fetch("finished_at"))
        raise InvalidArtifactError, "result finished before it started" if finished_at < started_at

        actual_duration = ((finished_at - started_at) * 1000).round
        declared_duration = timing.fetch("duration_ms")
        return if actual_duration == declared_duration

        raise InvalidArtifactError,
              "duration mismatch: timestamps imply #{actual_duration}ms, " \
              "artifact declares #{declared_duration}ms"
      rescue ArgumentError => error
        raise InvalidArtifactError, "invalid result timestamp: #{error.message}"
      end

      def verify_decision_evidence!(document, hard_gates, references)
        status = document.fetch("status")
        invalid_evidence = document.fetch("invalid_evidence")
        evidence_gaps = document.fetch("evidence_gaps")
        infrastructure_errors = document.fetch("infrastructure_errors")

        case status
        when "passed"
          if hard_gates.empty? || hard_gates.any? { |gate| gate.fetch("status") != "pass" }
            raise InvalidArtifactError, "passed result requires every applicable hard gate to pass"
          end
          raise InvalidArtifactError, "passed result requires referenced evidence" if references.empty?
          assert_no_diagnostic_errors!(status, invalid_evidence, evidence_gaps, infrastructure_errors)
        when "failed"
          unless hard_gates.any? { |gate| gate.fetch("status") == "fail" }
            raise InvalidArtifactError, "failed result requires at least one failed hard gate"
          end
          assert_no_diagnostic_errors!(status, invalid_evidence, evidence_gaps, infrastructure_errors)
        when "invalid"
          if invalid_evidence.empty?
            raise InvalidArtifactError, "invalid result must identify invalid evidence"
          end
          unless evidence_gaps.empty? && infrastructure_errors.empty?
            raise InvalidArtifactError, "invalid result cannot mix evidence gaps or infrastructure errors"
          end
        when "infrastructure_error"
          if infrastructure_errors.empty?
            raise InvalidArtifactError, "infrastructure result must identify an infrastructure error"
          end
          unless invalid_evidence.empty? && evidence_gaps.empty?
            raise InvalidArtifactError, "infrastructure result cannot mix evidence errors or gaps"
          end
        when "insufficient_evidence"
          unless hard_gates.any? { |gate| gate.fetch("status") == "unknown" } ||
                 !evidence_gaps.empty?
            raise InvalidArtifactError,
                  "insufficient result requires an unknown gate or identified evidence gap"
          end
          unless invalid_evidence.empty? && infrastructure_errors.empty?
            raise InvalidArtifactError, "insufficient result cannot mix invalid or infrastructure evidence"
          end
        end
      end

      def assert_no_diagnostic_errors!(status, invalid_evidence, evidence_gaps, infrastructure_errors)
        return if invalid_evidence.empty? && evidence_gaps.empty? && infrastructure_errors.empty?

        raise InvalidArtifactError, "#{status} result cannot contain evidence or infrastructure errors"
      end

      def read_stable_file(path, max_bytes:, kind:)
        raise InvalidArtifactError, "#{kind} byte budget exhausted" if max_bytes.negative?

        File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          before = file.stat
          raise ReferenceError, "#{path}: #{kind} is not a regular file" unless before.file?
          if before.size > max_bytes
            raise InvalidArtifactError, "#{path}: #{kind} exceeds #{max_bytes} bytes"
          end

          bytes = file.read(max_bytes + 1)
          if bytes.bytesize > max_bytes
            raise InvalidArtifactError, "#{path}: #{kind} exceeds #{max_bytes} bytes"
          end

          after = file.stat
          stable = before.ino == after.ino &&
                   before.size == after.size &&
                   before.mtime == after.mtime &&
                   before.ctime == after.ctime
          raise ReferenceError, "#{path}: #{kind} changed while being verified" unless stable

          bytes
        end
      end
    end
  end
end
