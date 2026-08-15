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

      Frame = Data.define(:system, :user, :facts, :digest, :catalog) do
        def fact_ids = facts.map { |entry| "fact:#{entry.fetch("id")}" }
      end

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

      def build(snapshot:, prompt:, prompt_version: nil, prompt_sha256: nil)
        verify_prompt!(prompt, prompt_version, prompt_sha256)
        facts = build_facts(snapshot)
        system = build_system(prompt)
        user = build_user(facts)
        bytes = Tamoz::Core.jcs(
          {"system" => system, "user" => user, "catalog" => @catalog.canonical}
        )
        Frame.new(
          system:,
          user:,
          facts:,
          digest: Tamoz::Core.digest(FRAME_DOMAIN,
                                    {"system" => system, "user" => user, "catalog" => @catalog.canonical}),
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
        lines << "EVIDENCE: cite facts only with the fact:<id> prefixes given " \
                 "in the user message."
        lines << "OUTPUT: strict JSON object matching the " \
                 "tamoz.episode-diagnosis/v2 protocol; no prose around it."
        lines.join("\n")
      end

      def build_user(facts)
        Tamoz::Core.jcs(
          {"situation" => facts.map { |entry| {"id" => "fact:#{entry.fetch("id")}", "value" => entry.fetch("value")} }}
        )
      end
    end
  end
end
