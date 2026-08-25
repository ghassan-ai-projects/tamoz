# frozen_string_literal: true

require "digest"

module Tamoz
  module Evals
    module Harness
      # DR-3 treatment harness (P11-ED work package): runs every (case,
      # treatment) cell with its own store file in its own tmpdir, and splits
      # the decisive metric (C1):
      #
      #   CI  — injection correctness (the reproducible gate number): the
      #         decisive turn's prompt carries EXACTLY the records the store +
      #         policy should have injected, sensitive records are never
      #         recalled, and prompt-injected content is never absorbed.
      #   live — attributable reuse (operator-run, TAMOZ_* env gate): a real
      #         provider + real retrieval; the operator supplies a live_adapter.
      #
      # CI structurally cannot claim attribution: the scripted model ignores
      # prompts, so `attribution_claimed` is always false in CI mode and the
      # scripted-control gate asserts all four treatments of every case produce
      # identical outcomes. The digest is computed over the non-exempt surface
      # (C5): `duration_ms` is declared exempt and zeroed for the digest.
      class MemoryTreatmentProfile
        TREATMENTS = %w[none experience knowledge wisdom].freeze
        REPORT_DOMAIN = "eval.memory-treatment-profile"
        REPORT_TYPE = "memory_treatment_profile"
        CI_DECISIVE_METRIC = "injection_correctness"
        LIVE_DECISIVE_METRIC = "attributable_reuse"
        EXEMPT_FIELDS = %w[duration_ms].freeze
        LIVE_ENV_GATE = "TAMOZ_MEMORY_LIVE"
        CONTROL_KEYS = %w[task_success model_calls steps terminal].freeze

        Report = Data.define(:document) do
          def initialize(document:)
            super(document: DeepFreeze.call(document))
          end

          def passed? = document.fetch("decision") == "pass"
          def to_h = document
          def to_json = CanonicalJSON.dump(document)
        end

        def initialize(
          corpus: AgentMemoryCorpus.new,
          mode: :ci,
          live_adapter: nil,
          auditor: AgentRunAudit.new,
          store_root: nil,
          store_factory: nil
        )
          @corpus = corpus
          @mode = mode
          @live_adapter = live_adapter
          @auditor = auditor
          @store_root = store_root
          @store_factory = store_factory
          validate_mode!
        end

        def run
          case @mode
          when :ci then run_ci
          when :live then run_live
          end
        rescue InvalidArtifactError, ExecutionError
          raise
        rescue StandardError
          raise ExecutionError, "memory treatment profile failed"
        end

        # The digest-reproducible surface: the report with exempt fields removed.
        def self.reproducible_surface(document)
          without_exempt(document)
        end

        def self.without_exempt(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, entry), out|
              next if EXEMPT_FIELDS.include?(key)

              out[key] = without_exempt(entry)
            end
          when Array
            value.map { |entry| without_exempt(entry) }
          else
            value
          end
        end
        private_class_method :without_exempt

        private

        def validate_mode!
          case @mode
          when :ci
            return unless @live_adapter

            raise ExecutionError, "CI treatment mode cannot carry a live adapter"
          when :live
            return if @live_adapter

            raise ExecutionError,
                  "live treatment mode requires a live_adapter (operator-run; " \
                  "#{LIVE_ENV_GATE}=1 gate)"
          else
            raise ExecutionError, "unknown treatment mode #{@mode.inspect}"
          end
        end

        def run_ci
          artifacts = @corpus.cases
          assert_mandatory_deltas!(artifacts)
          cells = if @store_root
                    run_cells(artifacts, @store_root)
                  else
                    Dir.mktmpdir("tamoz-memory-profile") { |root| run_cells(artifacts, root) }
                  end
          build_ci_report(artifacts, cells)
        end

        def run_cells(artifacts, root)
          artifacts.flat_map do |artifact|
            TREATMENTS.map do |treatment|
              MemoryCell.new(
                corpus: @corpus,
                case_artifact: artifact,
                treatment:,
                store_root: root,
                auditor: @auditor,
                store_factory: @store_factory
              ).run
            end
          end
        end

        # C6/E8 belt-and-braces: the Verifier already rejects memory-corpus cases
        # without a non-null expected_delta at load; the profile re-asserts it so
        # a corpus runner that skips the Verifier cannot slip a filler case in.
        def assert_mandatory_deltas!(artifacts)
          artifacts.each do |artifact|
            delta = artifact.to_h.dig("treatments", "expected_delta")
            next if delta

            raise UnsupportedFormatError,
                  "#{artifact['case_id']} requires treatments.expected_delta " \
                  "(failure_flip | cost_delta)"
          end
        end

        def build_ci_report(artifacts, cells)
          measurements = cells.map(&:measurement)
          aggregate = aggregate_ci(measurements)
          control = control_identical?(measurements)
          gates = [
            gate("sensitive_recall_zero", aggregate.fetch("sensitive_recalls").zero?),
            gate("unauthorized_recall_zero", aggregate.fetch("unauthorized_recalls").zero?),
            gate("injection_correct", aggregate.fetch("injection_correct_cells") == measurements.length),
            gate("store_integrity", aggregate.fetch("contaminated_cells").zero? &&
                                    aggregate.fetch("store_unstable_cells").zero?),
            gate("scripted_control_identical", control)
          ]
          document = {
            "report_type" => REPORT_TYPE,
            "format_version" => 1,
            "mode" => "ci",
            "decisive_metric" => CI_DECISIVE_METRIC,
            "attribution_claimed" => false,
            "exempt_fields" => EXEMPT_FIELDS,
            "corpus" => {
              "id" => AgentMemoryCorpus::SUITE_ID,
              "version" => AgentMemoryCorpus::SUITE_VERSION,
              "digest" => corpus_digest(artifacts),
              "case_count" => artifacts.length
            },
            "subject" => {
              "id" => "tamoz-agent",
              "version" => Tamoz::Agent::VERSION,
              "profile" => "controller-scripted",
              "model" => "scripted"
            },
            "evaluator" => {
              "id" => "tamoz-evals.memory-treatment",
              "version" => Tamoz::Evals::VERSION
            },
            "treatments" => TREATMENTS,
            "cells" => measurements,
            "control" => {
              "identical_across_treatments" => control,
              "compared_keys" => CONTROL_KEYS
            },
            "delta_measurement" => delta_summary(measurements),
            "aggregate" => aggregate,
            "hard_gates" => gates,
            "decision" => gates.all? { |entry| entry.fetch("status") == "pass" } ? "pass" : "fail"
          }
          final_report(document)
        end

        def aggregate_ci(measurements)
          {
            "cells" => measurements.length,
            "pass" => measurements.count { |entry| entry.fetch("outcome") == "pass" },
            "fail" => measurements.count { |entry| entry.fetch("outcome") == "fail" },
            "insufficient" => measurements.count { |entry| entry.fetch("outcome") == "insufficient" },
            "attribution_incomplete" =>
              measurements.count { |entry| entry.fetch("outcome") == "attribution_incomplete" },
            "injection_correct_cells" =>
              measurements.count { |entry| entry.fetch("injection_correct") == true },
            "sensitive_recalls" => measurements.sum { |entry| entry.fetch("sensitive_recalls") },
            "unauthorized_recalls" => measurements.sum { |entry| entry.fetch("unauthorized_recalls") },
            "decrypt_reads" => measurements.sum { |entry| entry.fetch("decrypt_reads") },
            "absorbed_prompt_content" =>
              measurements.sum { |entry| entry.fetch("absorbed_prompt_content") },
            "prompt_injections_seen" =>
              measurements.sum { |entry| entry.fetch("prompt_injections_seen") },
            "contaminated_cells" =>
              measurements.count { |entry| entry.fetch("reason") == "store_contamination" },
            "store_unstable_cells" =>
              measurements.count { |entry| entry.fetch("store_stable") == false },
            "attribution_incomplete_cells" =>
              measurements.count { |entry| entry.fetch("outcome") == "attribution_incomplete" }
          }
        end

        # The no-regression control: under the scripted model (which ignores
        # prompts) all four treatments of every case must produce identical
        # outcomes. This is what makes the CI number an injection-correctness
        # test and NOT a layer-value claim.
        def control_identical?(measurements)
          measurements.group_by { |entry| entry.fetch("case_id") }.all? do |_case_id, cells|
            signatures = cells.map { |entry| CONTROL_KEYS.map { |key| entry.fetch(key) } }
            signatures.uniq.length == 1
          end
        end

        def delta_summary(measurements)
          declared = measurements.group_by { |entry| entry.fetch("case_id") }.transform_values do |cells|
            cells.first.fetch("expected_delta")
          end
          {
            "ci_claim" => "none",
            "declared_deltas" => declared,
            "observed_flips" => 0,
            "scripted_control" => control_identical?(measurements) ? "identical" : "diverged",
            "note" =>
              "ScriptedModel ignores prompts, so CI measures injection " \
              "correctness only; attributable reuse is a live-layer " \
              "(operator-run) claim."
          }
        end

        def run_live
          artifacts = @corpus.cases
          assert_mandatory_deltas!(artifacts)
          cells = artifacts.flat_map do |artifact|
            TREATMENTS.map { |treatment| @live_adapter.run(artifact, treatment:) }
          end
          aggregate = aggregate_live(cells)
          gates = [
            gate("sensitive_recall_zero", aggregate.fetch("sensitive_recalls").zero?),
            gate("unauthorized_recall_zero", aggregate.fetch("unauthorized_recalls").zero?)
          ]
          document = {
            "report_type" => REPORT_TYPE,
            "format_version" => 1,
            "mode" => "live",
            "decisive_metric" => LIVE_DECISIVE_METRIC,
            "attribution_claimed" => true,
            "attribution_basis" => "live_adapter (operator-run, #{LIVE_ENV_GATE}=1)",
            "exempt_fields" => EXEMPT_FIELDS,
            "corpus" => {
              "id" => AgentMemoryCorpus::SUITE_ID,
              "version" => AgentMemoryCorpus::SUITE_VERSION,
              "digest" => corpus_digest(artifacts),
              "case_count" => artifacts.length
            },
            "evaluator" => {
              "id" => "tamoz-evals.memory-treatment",
              "version" => Tamoz::Evals::VERSION
            },
            "treatments" => TREATMENTS,
            "cells" => cells,
            "aggregate" => aggregate,
            "hard_gates" => gates,
            "decision" => gates.all? { |entry| entry.fetch("status") == "pass" } ? "pass" : "fail"
          }
          final_report(document)
        end

        # Live measurements come from the operator's adapter with at least:
        # task_success, model_calls, steps, sensitive_recalls,
        # unauthorized_recalls, attributable_reuses, precision_at_k,
        # helpful_recall_at_k. Live numbers are declared non-digest-reproducible
        # by design (C2).
        def aggregate_live(cells)
          {
            "cells" => cells.length,
            "task_successes" => cells.count { |entry| entry.fetch("task_success") == true },
            "attributable_reuses" => cells.sum { |entry| entry.fetch("attributable_reuses", 0) },
            "precision_at_k" => cells.sum { |entry| entry.fetch("precision_at_k", 0) },
            "helpful_recall_at_k" => cells.sum { |entry| entry.fetch("helpful_recall_at_k", 0) },
            "sensitive_recalls" => cells.sum { |entry| entry.fetch("sensitive_recalls") },
            "unauthorized_recalls" => cells.sum { |entry| entry.fetch("unauthorized_recalls") }
          }
        end

        def final_report(document)
          document["content_digest"] = CanonicalJSON.content_digest(
            self.class.reproducible_surface(document),
            domain: REPORT_DOMAIN
          )
          Report.new(document:)
        end

        def gate(id, passed)
          {"id" => id, "status" => passed ? "pass" : "fail"}
        end

        def corpus_digest(artifacts)
          body = artifacts.map do |artifact|
            {
              "case_id" => artifact["case_id"],
              "case_version" => artifact["case_version"],
              "case_digest" => artifact.digest
            }
          end
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(body))}"
        end
      end
    end
  end
end
