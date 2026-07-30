# frozen_string_literal: true

require "json"
require "time"

module Tamoz
  module Evals
    class Verifier
      MAX_ARTIFACT_BYTES = 2 * 1024 * 1024
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
        expanded_path = File.expand_path(path)
        document = read_document(expanded_path)
        artifact_type = document["artifact_type"]
        domain = DIGEST_DOMAINS.fetch(artifact_type) do
          raise UnsupportedFormatError, "unsupported artifact type: #{artifact_type.inspect}"
        end

        Schema.load(artifact_type).validate!(document)
        verify_digest!(document, domain)
        references = verify_references!(document.fetch("references"), expanded_path)
        decision = verify_semantics!(artifact_type, document)

        Verification.new(
          path: expanded_path.freeze,
          artifact_type: artifact_type.freeze,
          decision: decision.freeze,
          digest: document.fetch("content_digest").freeze,
          document: CanonicalJSON.normalize(document),
          references: references.freeze
        ).freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
        raise ReferenceError, "#{expanded_path}: #{error.message}"
      rescue JSON::ParserError => error
        raise InvalidArtifactError, "#{expanded_path}: invalid JSON: #{error.message}"
      end

      private

      def read_document(path)
        size = File.size(path)
        if size > MAX_ARTIFACT_BYTES
          raise InvalidArtifactError, "#{path}: artifact exceeds #{MAX_ARTIFACT_BYTES} bytes"
        end

        bytes = File.binread(path)
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

        references.map do |reference|
          relative_path = reference.fetch("path")
          if Pathname.new(relative_path).absolute? || relative_path.split(File::SEPARATOR).include?("..")
            raise ReferenceError, "reference path escapes artifact directory: #{relative_path.inspect}"
          end

          candidate = File.expand_path(relative_path, root)
          real_path = File.realpath(candidate)
          unless real_path.start_with?("#{root}#{File::SEPARATOR}")
            raise ReferenceError, "reference resolves outside artifact directory: #{relative_path.inspect}"
          end

          actual_digest = CanonicalJSON.file_digest(real_path)
          expected_digest = reference.fetch("digest")
          unless actual_digest == expected_digest
            raise DigestError,
                  "reference digest mismatch for #{relative_path}: expected #{expected_digest}, " \
                  "got #{actual_digest}"
          end

          {
            "id" => reference.fetch("id"),
            "path" => real_path,
            "digest" => actual_digest
          }.freeze
        end
      end

      def verify_semantics!(artifact_type, document)
        return "verified" if artifact_type == "case"

        expected = RESULT_DECISIONS.fetch(document.fetch("status"))
        actual = document.fetch("decision")
        unless actual == expected
          raise InvalidArtifactError,
                "result status #{document.fetch("status").inspect} requires decision " \
                "#{expected.inspect}, got #{actual.inspect}"
        end

        references = document.fetch("references")
        hard_gates = document.fetch("hard_gates")
        assert_unique_ids!(references, "references")
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

        verify_timing!(document.fetch("timing"))
        verify_decision_evidence!(document, hard_gates, references)
        actual
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

        case status
        when "passed"
          if hard_gates.empty? || hard_gates.any? { |gate| gate.fetch("status") != "pass" }
            raise InvalidArtifactError, "passed result requires every applicable hard gate to pass"
          end
          raise InvalidArtifactError, "passed result requires referenced evidence" if references.empty?
          unless document.fetch("invalid_evidence").empty?
            raise InvalidArtifactError, "passed result cannot contain invalid evidence"
          end
        when "failed"
          unless hard_gates.any? { |gate| gate.fetch("status") == "fail" }
            raise InvalidArtifactError, "failed result requires at least one failed hard gate"
          end
        when "invalid"
          if document.fetch("invalid_evidence").empty?
            raise InvalidArtifactError, "invalid result must identify invalid evidence"
          end
        when "insufficient_evidence"
          unless hard_gates.any? { |gate| gate.fetch("status") == "unknown" } ||
                 !document.fetch("invalid_evidence").empty?
            raise InvalidArtifactError,
                  "insufficient result requires an unknown gate or identified evidence gap"
          end
        end
      end
    end
  end
end
