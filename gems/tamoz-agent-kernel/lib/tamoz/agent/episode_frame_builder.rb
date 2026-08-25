# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P1/§3.1: the deterministic frame builder for the episode graph. The frame
    # has two sections:
    #
    #   - trusted policy section: the operator-authored prompt (digest-verified
    #     against the wire's prompt_sha256), the objective, and the diagnosis
    #     catalog (wire-digest-verified by DiagnosisCatalog.verify_wire);
    #   - untrusted situation section: the verified snapshot's facts, each with
    #     a stable `fact:<index>` reference the model may cite, plus any
    #     recalled memory (P5).
    #
    # The frame's canonical digest binds the exact system/user bytes the frozen
    # transport sends, so the receipt's request digest is the frame digest.
    # No model call and no authority: this node only assembles and verifies.
    class EpisodeFrameBuilder
      FRAME_DOMAIN = "tamoz.agent.episode_frame.v1\n"
      MAX_FACT_BYTES = 4096
      MAX_FACTS = 64

      Frame = Data.define(:system, :user, :facts, :evidence_ids, :digest, :catalog)

      # catalog: a DiagnosisCatalog (already wire-verified). prompt_sha256 is
      # optional — when present the prompt bytes must match it or the frame
      # fails closed before any model call.
      def initialize(catalog:, objective: "")
        @catalog = catalog
        @objective = String(objective).freeze
        freeze
      end

      def verify_prompt!(prompt, prompt_version, expected_sha256)
        return if expected_sha256.to_s.empty?

        actual = prompt_digest(prompt, prompt_version)
        unless actual == Tamoz::Core.normalize_digest(expected_sha256.to_s)
          raise EpisodeFrameError, "episode_frame/prompt_digest_mismatch"
        end

        actual
      end

      def build(snapshot:, prompt:, prompt_version: nil, prompt_sha256: nil,
                skills: [], memory: [], tool_results: [], repair_directive: nil)
        verify_prompt!(prompt, prompt_version, prompt_sha256)
        facts = build_facts(snapshot)
        system = build_system(prompt)
        user = build_user(facts, skills, memory, tool_results, repair_directive)
        canonical = {"system" => system, "user" => user, "catalog" => @catalog.canonical}
        evidence_ids = build_evidence_ids(facts, skills, memory, tool_results)
        Frame.new(
          system:,
          user:,
          facts:,
          evidence_ids: evidence_ids.freeze,
          digest: Tamoz::Core.digest(FRAME_DOMAIN, canonical),
          catalog: @catalog
        )
      end

      # The prompt digest is the CROSS-REPO contract: the Go runtime computes
      # digest("situation-runtime/prompt/v1\n", {version, text}) for the static
      # configured prompt (assembler.go), and the frame must verify with the
      # SAME domain and canonicalization or a Go-driven episode fails closed.
      def prompt_digest(prompt, prompt_version)
        Tamoz::Core.digest(
          "situation-runtime/prompt/v1\n",
          {"version" => String(prompt_version), "text" => String(prompt)}
        )
      end

      private

      def build_facts(snapshot)
        raw = snapshot.fetch("facts", {})
        unless raw.is_a?(Hash)
          raise EpisodeFrameError, "episode_frame/facts_not_object"
        end

        entries = []
        raw.each do |name, value|
          break if entries.length >= MAX_FACTS

          entry = {"id" => name.to_s, "name" => name.to_s, "value" => value}
          unless Tamoz::Core.jcs(entry).bytesize <= MAX_FACT_BYTES
            raise EpisodeFrameError, "episode_frame/fact_too_large: #{name}"
          end

          entries << entry
        end
        entries
      end

      def build_system(prompt)
        lines = [String(prompt)]
        lines << "OBJECTIVE: #{@objective}" unless @objective.empty?
        lines << "DIAGNOSIS CODES (output exactly these codes in " \
                 "diagnosis_probabilities; cover every code once; probabilities " \
                 "must be in [0,1] and sum to 1):"
        @catalog.entries.each do |entry|
          lines << "- #{entry.code}: #{entry.description}"
        end
        lines << "EVIDENCE: cite facts with the fact:<id> prefixes, tools with " \
                 "tool:<index>, memory with memory:<digest>, and skills with " \
                 "skill:<name> — all only for entries given in the user message."
        lines << "OUTPUT: strict JSON object matching the " \
                 "tamoz.episode-diagnosis/v2 protocol; no prose around it."
        lines.join("\n")
      end

      # The untrusted section: every entry is fenced + attributed — skills,
      # memory, snapshot facts, tool results, and corrections are all data
      # with stable evidence ids, never raw prompt text.
      def build_user(facts, skills, memory, tool_results, repair_directive)
        situation = build_situation_entries(facts)
        skill_entries = build_skill_entries(skills)
        memory_entries = build_memory_entries(memory)
        tools = build_tool_entries(tool_results)
        user = {"situation" => situation}
        user["skills"] = skill_entries unless skill_entries.empty?
        user["memory"] = memory_entries unless memory_entries.empty?
        user["tool_results"] = tools unless tools.empty?
        user["repair_directive"] = repair_directive if repair_directive
        Tamoz::Core.jcs(user)
      end

      def build_situation_entries(facts)
        facts.map do |entry|
          {"id" => "fact:#{entry.fetch("id")}", "value" => entry.fetch("value")}
        end
      end

      def build_skill_entries(skills)
        Array(skills).map do |entry|
          {
            "id" => "skill:#{entry.name}",
            "tree_sha256" => entry.tree_digest,
            "text" => entry.text
          }
        end
      end

      def build_memory_entries(memory)
        Array(memory).map do |entry|
          {
            "id" => "memory:#{entry.fetch("digest")}",
            "statement" => entry.fetch("statement")
          }
        end
      end

      def build_tool_entries(tool_results)
        Array(tool_results).map.with_index do |result, index|
          {
            "id" => "tool:#{index}",
            "name" => result.fetch("tool"),
            "request_sha256" => result["request_digest"],
            "result_sha256" => result["result_sha256"],
            "is_error" => result.fetch("is_error", false),
            "result_bytes" => result.fetch("result_bytes", 0)
          }
        end
      end

      def build_evidence_ids(facts, skills, memory, tool_results)
        (
          facts.map { |entry| "fact:#{entry.fetch("id")}" } +
          Array(skills).map { |entry| "skill:#{entry.name}" } +
          Array(memory).map { |entry| "memory:#{entry.fetch("digest")}" } +
          Array(tool_results).each_index.map { |index| "tool:#{index}" }
        )
      end
    end
  end
end
