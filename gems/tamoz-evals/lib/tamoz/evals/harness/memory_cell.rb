# frozen_string_literal: true

require "fileutils"

module Tamoz
  module Evals
    module Harness
      # One (case, treatment) cell: its own tmpdir, its own store file (C4), a
      # pre-run seed-digest assertion (E7), and a single digest-stable
      # measurement. Outcome classes follow C9/E2:
      #
      #   pass                    — run clean, seed intact, injection exact;
      #   fail                    — injection mismatch or store integrity break;
      #   insufficient            — the cell run crashed;
      #   attribution_incomplete  — an injection was decided but no
      #                             `:memory_recalled` mark reached the stream.
      class MemoryCell
        MEMORY_EVENT = MemoryEnvelope::MEMORY_EVENT

        attr_reader :case_artifact, :treatment, :store, :execution, :measurement

        def initialize(
          corpus:,
          case_artifact:,
          treatment:,
          store_root:,
          auditor: AgentRunAudit.new,
          store: nil
        )
          @corpus = corpus
          @case_artifact = case_artifact
          @treatment = treatment
          @store_root = store_root
          @auditor = auditor
          @store = store
        end

        def run
          @cell_root = Dir.mktmpdir("tamoz-memory-cell", @store_root)
          @captures = []
          @store ||= seed_store
          @duration_ms = nil
          @crashed = nil
          @seed_intact_pre = @store.seed_intact?
          @execution = run_execution if @seed_intact_pre
          @measurement = build_measurement
          self
        end

        def seed_store
          fixtures = @case_artifact.to_h.fetch("treatments", {}).dig("seed", "fixtures")
          path = File.join(@cell_root, "store", "store.json")
          MemoryStore.seed(path, fixtures)
        end

        private

        def run_execution
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          execution = @corpus.run_cell(
            @case_artifact,
            cell_root: @cell_root,
            store: @store,
            memory_config: {"epoch" => @treatment},
            memory_capture: @captures
          )
          @duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).ceil
          execution
        rescue ExecutionError => error
          @crashed = error.message
          nil
        rescue StandardError => error
          @crashed = "#{error.class}: #{error.message}"
          nil
        end

        def build_measurement
          events = @execution ? @execution.events : []
          audit = @execution ? @auditor.call(@execution) : nil
          injected_ids = @captures.flat_map { |capture| capture.fetch("injected_ids") }.uniq
          event_ids = memory_event_ids(events)
          prompt_ids = prompt_marker_ids(@captures)
          echo_ids = @captures.flat_map { |capture| capture.fetch("prompt_echoed_ids") }.uniq
          injections_seen = @captures.sum { |capture| capture.fetch("prompt_injections") }
          matched_restricted = @captures.flat_map do |capture|
            capture.fetch("matched_restricted_ids")
          end.uniq
          expected = @case_artifact.to_h.dig("treatments", "expected_delta")

          correct = !@crashed &&
            @seed_intact_pre && @store.seed_intact? &&
            (injected_ids - event_ids).empty? &&
            (event_ids - injected_ids).empty? &&
            (injected_ids - prompt_ids).empty? &&
            (prompt_ids - injected_ids).empty? &&
            echo_ids.empty? &&
            (audit ? audit.fetch("sensitive_recalls") : 0).zero? &&
            (audit ? audit.fetch("unauthorized_recalls") : 0).zero? &&
            @store.decrypt_reads.zero? &&
            @store.absorbed_count.zero?

          DeepFreeze.call(
            "case_id" => @case_artifact["case_id"],
            "treatment" => @treatment,
            "outcome" => outcome(correct),
            "reason" => reason(correct),
            "injection_correct" => correct,
            "injected_ids" => injected_ids,
            "event_ids" => event_ids,
            "prompt_ids" => prompt_ids,
            "missing_ids" => (injected_ids - event_ids) + (injected_ids - prompt_ids),
            "extra_ids" => (event_ids - injected_ids) + (prompt_ids - injected_ids),
            "matched_restricted_ids" => matched_restricted,
            "sensitive_recalls" => audit ? audit.fetch("sensitive_recalls") : 0,
            "unauthorized_recalls" => audit ? audit.fetch("unauthorized_recalls") : 0,
            "decrypt_reads" => @store.decrypt_reads,
            "absorbed_prompt_content" => @store.absorbed_count,
            "prompt_echoed_ids" => echo_ids,
            "prompt_injections_seen" => injections_seen,
            "seed_digest" => @store.seed_digest,
            "store_digest" => @store.digest,
            "store_stable" => @store.seed_intact?,
            "task_success" => @execution ? @execution.oracle_success : false,
            "terminal" => @execution ? @execution.terminal : (@crashed ? "crashed" : "not_run"),
            "model_calls" => @execution ? @execution.model_calls.length : 0,
            "steps" => planned_steps(events),
            "expected_delta" => expected,
            "delta_observed" => false,
            "vacuous" => @treatment == "none",
            "duration_ms" => @duration_ms || 0
          )
        end

        def outcome(correct)
          return "insufficient" if @crashed
          return "fail" unless @seed_intact_pre && @store.seed_intact?
          return "attribution_incomplete" if marks_missing_but_injection_expected?

          correct ? "pass" : "fail"
        end

        def reason(correct)
          return "run_crashed" if @crashed
          return "store_contamination" unless @seed_intact_pre
          return "store_mutated_during_run" unless @store.seed_intact?
          return "attribution_mark_absent" if marks_missing_but_injection_expected?
          return "injection_mismatch" unless correct

          "ok"
        end

        # E2: the retrieval layer decided to inject, but no `:memory_recalled`
        # mark ever reached the event stream. The mark AND the flip are both
        # required for attribution; a missing mark makes the cell
        # attribution_incomplete, never a credited reuse.
        def marks_missing_but_injection_expected?
          return false if @treatment == "none"

          expected_ids = @captures.flat_map { |capture| capture.fetch("injected_ids") }.uniq
          !expected_ids.empty? && memory_event_ids(@execution ? @execution.events : []).empty?
        end

        def memory_event_ids(events)
          events.select { |event| event.type == MEMORY_EVENT }
                .map { |event| event.data.fetch("memory_id") }
                .uniq
        end

        def prompt_marker_ids(captures)
          captures.flat_map do |capture|
            capture.fetch("effective_prompt").scan(/\[([^\]]+?) v\d+\]/).flatten
          end.uniq
        end

        def planned_steps(events)
          events.sum do |event|
            event.type == :plan_drafted ? event.data.fetch("plan").fetch("steps").length : 0
          end
        end
      end
    end
  end
end
