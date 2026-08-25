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
        "evidence" => "eval.evidence",
        "result" => "eval.result"
      }.freeze
      # DR-3 (C6/E8): memory-corpus cases must declare a non-null
      # `treatments.expected_delta` (`failure_flip | cost_delta`). This is the
      # closing of the filler-case hole; it is enforced only for the memory
      # suite so the scorecard corpus (17 cases, phase-owned) is untouched.
      MEMORY_EVAL_SUITE_ID = "tamoz.agent.memory"
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
        expanded_path = expand_artifact_path(path)
        document = read_document(expanded_path)
        artifact_type = document["artifact_type"]
        domain = DIGEST_DOMAINS.fetch(artifact_type) do
          raise UnsupportedFormatError, "unsupported artifact type: #{artifact_type.inspect}"
        end

        Schema.load(artifact_type).validate!(document)
        verify_digest!(document, domain)
        validate_unique_ids!(document.fetch("references"), "references")
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

      def expand_artifact_path(path)
        raw_path = begin
          File.path(path)
        rescue TypeError, ArgumentError => error
          raise ReferenceError, "invalid artifact path: #{error.message}"
        end
        raise ReferenceError, "artifact path contains a NUL byte" if raw_path.include?("\0")

        File.expand_path(raw_path)
      end

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
          real_path = resolve_reference_path!(relative_path, root)

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

      def resolve_reference_path!(relative_path, root)
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

        real_path
      end

      def verify_semantics!(artifact_type, document)
        case artifact_type
        when "case"
          verify_case_semantics!(document)
          "verified"
        when "evidence"
          verify_evidence_semantics!(document)
        else
          # only "result" reaches here: verify rejects other types via DIGEST_DOMAINS
          verify_result_semantics!(document)
        end
      end

      def verify_result_semantics!(document)
        expected = RESULT_DECISIONS.fetch(document.fetch("status"))
        actual = document.fetch("decision")
        unless actual == expected
          raise InvalidArtifactError,
                "result status #{document.fetch("status").inspect} requires decision " \
                "#{expected.inspect}, got #{actual.inspect}"
        end

        references = document.fetch("references")
        hard_gates = document.fetch("hard_gates")
        validate_unique_ids!(hard_gates, "hard_gates")
        validate_unique_ids!(document.fetch("scores"), "scores")
        reference_ids = references.map { |reference| reference.fetch("id") }

        validate_citations!("hard gate", hard_gates, cited_field: "evidence_ids", reference_ids: reference_ids)
        verify_provenance!(document, reference_ids)
        verify_timing!(document.fetch("timing"))
        verify_decision_evidence!(document, hard_gates, references)
        actual
      end

      def verify_case_semantics!(document)
        evidence = document.fetch("evidence")
        evidence_specs = evidence.fetch("required") + evidence.fetch("optional")
        validate_unique_ids!(evidence_specs, "evidence")
        validate_unique_ids!(document.fetch("scorers"), "scorers")

        capabilities = document.fetch("capabilities")
        overlap = capabilities.fetch("allowed") & capabilities.fetch("prohibited")
        unless overlap.empty?
          raise InvalidArtifactError,
                "capabilities cannot be both allowed and prohibited: #{overlap.sort.inspect}"
        end

        # DR-3 (C6/E8): the mandatory treatments.expected_delta block. `null` is
        # rejected for memory-corpus cases; the schema already rejects a null
        # value inside the block, so this guards against the block being absent.
        if document.fetch("suite_id") == MEMORY_EVAL_SUITE_ID &&
           document.dig("treatments", "expected_delta").nil?
          raise UnsupportedFormatError,
                "memory-corpus case requires treatments.expected_delta " \
                "(failure_flip | cost_delta)"
        end
      end

      def verify_evidence_semantics!(document)
        references = document.fetch("references")
        reference_ids = references.map { |reference| reference.fetch("id") }
        claims = document.fetch("claims")
        measurements = document.fetch("measurements")
        validate_unique_ids!(claims, "claims")
        validate_unique_ids!(measurements, "measurements")
        content_policy = document.fetch("content_policy")
        if content_policy.fetch("classification") == "public" &&
           !content_policy.fetch("sanitized")
          raise InvalidArtifactError,
                "public evidence must declare sanitized content"
        end

        validate_citations!("claim", claims, cited_field: "evidence_ids", reference_ids: reference_ids)

        processes = document.fetch("processes")
        verify_evidence_processes!(document, processes)
        verify_evidence_timing!(document, processes)
        verify_evidence_status!(document, claims)
        RESULT_DECISIONS.fetch(document.fetch("status"))
      end

      def verify_evidence_processes!(document, processes)
        validate_unique_ids!(processes, "processes")
        processes.each { |process| verify_evidence_process!(process) }
        if %w[process crash race fault].include?(document.fetch("kind")) &&
           processes.empty?
          raise InvalidArtifactError,
                "#{document.fetch("kind")} evidence requires a process record"
        end
        if document.fetch("selection") &&
           processes.none? { |process| intentional_intervention?(process) }
          raise InvalidArtifactError,
                "selector evidence requires an intentional SIGKILL process record"
        end
      end

      def verify_evidence_timing!(document, processes)
        timing = document.fetch("timing")
        verify_timing!(timing)
        process_exceeds_envelope = processes.any? do |process|
          process.fetch("duration_ms") > timing.fetch("duration_ms")
        end
        return unless process_exceeds_envelope

        raise InvalidArtifactError,
              "process duration exceeds evidence envelope duration"
      end

      def verify_evidence_process!(process)
        return unless process

        verify_process_status_consistency!(process)
        verify_process_termination_action!(process)
        verify_process_kill_signal!(process)
        verify_process_streams!(process)
      end

      def verify_process_status_consistency!(process)
        exited = !process.fetch("exit_status").nil?
        signaled = !process.fetch("term_signal").nil?
        if exited == signaled
          raise InvalidArtifactError,
                "evidence process requires exactly one exit status or terminating signal"
        end

        timed_out = process.fetch("timed_out")
        termination_reason = process.fetch("termination_reason")
        return if timed_out == (termination_reason == "timeout")

        raise InvalidArtifactError,
              "process timed_out and termination reason disagree"
      end

      def verify_process_termination_action!(process)
        termination = process.fetch("termination")
        termination_reason = process.fetch("termination_reason")
        case termination_reason
        when "none"
          unless termination == "none"
            raise InvalidArtifactError, "ordinary process termination requires no harness action"
          end
        when "timeout"
          if termination == "none"
            raise InvalidArtifactError, "process timeout requires a harness termination action"
          end
        when "intervention"
          unless intentional_intervention?(process)
            raise InvalidArtifactError, "process intervention requires intentional SIGKILL status"
          end
        when "cleanup"
          if termination == "none"
            raise InvalidArtifactError, "process cleanup requires a harness termination action"
          end
        end
      end

      def verify_process_kill_signal!(process)
        return unless process.fetch("termination") == "kill"
        return if process.fetch("term_signal") == "KILL"

        raise InvalidArtifactError,
              "SIGKILL harness termination requires KILL process status"
      end

      def verify_process_streams!(process)
        %w[stdout stderr].each do |name|
          stream = process.fetch(name)
          bytes = stream.fetch("bytes")
          captured = stream.fetch("captured_bytes")
          if captured > bytes
            raise InvalidArtifactError,
                  "#{name} captured bytes exceed produced bytes"
          end
          unless stream.fetch("truncated") == (captured < bytes)
            raise InvalidArtifactError,
                  "#{name} truncation flag disagrees with byte counts"
          end
        end
      end

      def verify_evidence_status!(document, claims)
        diagnostics = document.fetch("diagnostics")
        invalid = diagnostics.fetch("invalid_evidence")
        gaps = diagnostics.fetch("evidence_gaps")
        infrastructure = diagnostics.fetch("infrastructure_errors")

        case document.fetch("status")
        when "passed"
          if document.fetch("processes").any? do |process|
               process.fetch("termination_reason") == "cleanup"
             end
            raise InvalidArtifactError,
                  "passed evidence cannot rely on cleanup termination"
          end
          unless claims.all? { |claim| claim.fetch("status") == "pass" }
            raise InvalidArtifactError,
                  "passed evidence requires every claim to pass"
          end
          validate_no_diagnostic_errors!("passed evidence", invalid, gaps, infrastructure)
        when "failed"
          unless claims.any? { |claim| claim.fetch("status") == "fail" }
            raise InvalidArtifactError,
                  "failed evidence requires at least one failed claim"
          end
          validate_no_diagnostic_errors!("failed evidence", invalid, gaps, infrastructure)
        when "invalid"
          if invalid.empty?
            raise InvalidArtifactError,
                  "invalid evidence must identify invalid material"
          end
          unless gaps.empty? && infrastructure.empty?
            raise InvalidArtifactError,
                  "invalid evidence cannot mix gaps or infrastructure errors"
          end
        when "infrastructure_error"
          if infrastructure.empty?
            raise InvalidArtifactError,
                  "infrastructure evidence must identify an infrastructure error"
          end
          unless invalid.empty? && gaps.empty?
            raise InvalidArtifactError,
                  "infrastructure evidence cannot mix invalid material or gaps"
          end
        when "insufficient_evidence"
          unless claims.any? { |claim| claim.fetch("status") == "unknown" } ||
                 !gaps.empty?
            raise InvalidArtifactError,
                  "insufficient evidence requires an unknown claim or evidence gap"
          end
          unless invalid.empty? && infrastructure.empty?
            raise InvalidArtifactError,
                  "insufficient evidence cannot mix invalid or infrastructure material"
          end
        end
      end

      def intentional_intervention?(process)
        process.fetch("termination") == "kill" &&
          process.fetch("termination_reason") == "intervention" &&
          process.fetch("term_signal") == "KILL" &&
          !process.fetch("timed_out")
      end

      def verify_provenance!(document, reference_ids)
        verify_provenance_components!(document)
        verify_provenance_structure!(document)
        verify_provenance_citations!(document, reference_ids)
      end

      def verify_provenance_components!(document)
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
        return if %w[id version digest].all? { |key| gate.fetch(key) == authority.fetch(key) }

        raise InvalidArtifactError, "decision authority does not match the provenance gate"
      end

      def verify_provenance_structure!(document)
        provenance = document.fetch("provenance")
        attempts = provenance.fetch("attempts")
        validate_unique_ids!(attempts, "attempts")
        attempt_indexes = attempts.map { |attempt| attempt.fetch("index") }
        unless attempt_indexes.uniq.length == attempt_indexes.length
          raise InvalidArtifactError, "provenance attempts contain duplicate indexes"
        end
        validate_unique_ids!(provenance.fetch("fixtures"), "fixtures")
        snapshot_kinds = provenance.fetch("snapshots").map { |snapshot| snapshot.fetch("kind") }
        unless snapshot_kinds.uniq.length == snapshot_kinds.length
          raise InvalidArtifactError, "provenance snapshots contain duplicate kinds"
        end

        repetition = provenance.fetch("repetition")
        return unless repetition.fetch("index") > repetition.fetch("count")

        raise InvalidArtifactError, "repetition index exceeds repetition count"
      end

      def verify_provenance_citations!(document, reference_ids)
        attempts = document.fetch("provenance").fetch("attempts")
        validate_citations!("attempt", attempts, cited_field: "reference_ids", reference_ids: reference_ids)

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

      def validate_citations!(kind, records, cited_field:, reference_ids:)
        records.each do |record|
          missing = record.fetch(cited_field) - reference_ids
          next if missing.empty?

          raise InvalidArtifactError,
                "#{kind} #{record.fetch("id").inspect} cites missing evidence #{missing.inspect}"
        end
      end

      def validate_unique_ids!(records, field)
        ids = records.map { |record| record.fetch("id") }
        duplicates = ids.tally.select { |_id, count| count > 1 }.keys
        return if duplicates.empty?

        raise InvalidArtifactError, "#{field} contain duplicate ids: #{duplicates.sort.inspect}"
      end

      def verify_timing!(timing)
        started_at = Time.iso8601(timing.fetch("started_at"))
        finished_at = Time.iso8601(timing.fetch("finished_at"))
        raise InvalidArtifactError, "artifact finished before it started" if finished_at < started_at

        actual_duration = ((finished_at - started_at) * 1000).round
        declared_duration = timing.fetch("duration_ms")
        return if actual_duration == declared_duration

        raise InvalidArtifactError,
              "duration mismatch: timestamps imply #{actual_duration}ms, " \
              "artifact declares #{declared_duration}ms"
      rescue ArgumentError => error
        raise InvalidArtifactError, "invalid artifact timestamp: #{error.message}"
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
          validate_no_diagnostic_errors!(
            "#{status} result",
            invalid_evidence,
            evidence_gaps,
            infrastructure_errors
          )
        when "failed"
          unless hard_gates.any? { |gate| gate.fetch("status") == "fail" }
            raise InvalidArtifactError, "failed result requires at least one failed hard gate"
          end
          validate_no_diagnostic_errors!(
            "#{status} result",
            invalid_evidence,
            evidence_gaps,
            infrastructure_errors
          )
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

      def validate_no_diagnostic_errors!(label, invalid_evidence, evidence_gaps, infrastructure_errors)
        return if invalid_evidence.empty? && evidence_gaps.empty? && infrastructure_errors.empty?

        raise InvalidArtifactError,
              "#{label} cannot contain evidence or infrastructure errors"
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
