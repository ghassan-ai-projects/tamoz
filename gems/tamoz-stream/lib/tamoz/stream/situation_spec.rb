# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Stream
    # P14-C (plan §6, design §9) — the SituationSpec: deterministic
    # configuration, NOT user code. Compilation rejects scripts, model calls,
    # I/O, nondeterministic iteration, host-timezone dependence, and unbounded
    # state. The canonical compiled form has a digest, reusing the P8/P9
    # artifact-digest pattern (canonicalized JSON + domain separator) — never a
    # new compiler scheme.
    #
    # The compiled spec declares the risk ceiling, freshness/deadline policy,
    # and the cognition admission policy (debounce/cooldown/cost). The runtime
    # `reduce`/`situation`/`trigger` operators are INJECTED (pure callables);
    # this value is the deterministic contract that pins their bounds.
    SituationSpec = Data.define(
      :spec_id, :version, :schema_id, :risk_class,
      :max_confidence, :freshness_seconds, :deadline_seconds,
      :debounce_seconds, :cooldown_seconds, :max_cost_estimate,
      :late_data_policy, :idle_after_seconds,
      :spec_digest
    ) do
      DIGEST_DOMAIN = "tamoz.stream.situation_spec.v1\n"
      RISK_CLASSES = %i[r0_observe r1_notify r2_bounded r3_denied r4_advisory].freeze
      LATE_DATA_POLICIES = %i[drop_with_audit history_only correct correct_and_reconsider].freeze

      def initialize(
        spec_id:, version: 1, schema_id:, risk_class: :r1_notify,
        max_confidence: 0.95, freshness_seconds: 30, deadline_seconds: 60,
        debounce_seconds: 5, cooldown_seconds: 60, max_cost_estimate: 100,
        late_data_policy: :drop_with_audit, idle_after_seconds: 120,
        spec_digest: nil
      )
        validated = validate!(
          spec_id:, version:, schema_id:, risk_class:,
          max_confidence:, freshness_seconds:, deadline_seconds:,
          debounce_seconds:, cooldown_seconds:, max_cost_estimate:,
          late_data_policy:, idle_after_seconds:
        )
        @digest = spec_digest || compute_digest(validated)
        super(**validated, spec_digest: @digest)
      end

      def to_h
        {
          "spec_id" => spec_id, "version" => version, "schema_id" => schema_id,
          "risk_class" => risk_class.to_s, "max_confidence" => max_confidence,
          "freshness_seconds" => freshness_seconds,
          "deadline_seconds" => deadline_seconds,
          "debounce_seconds" => debounce_seconds,
          "cooldown_seconds" => cooldown_seconds,
          "max_cost_estimate" => max_cost_estimate,
          "late_data_policy" => late_data_policy.to_s,
          "idle_after_seconds" => idle_after_seconds,
          "spec_digest" => spec_digest
        }
      end

      private

      def compute_digest(fields)
        definition = fields.reject { |key, _value| key == :spec_digest }
        "sha256:#{Digest::SHA256.hexdigest(
          DIGEST_DOMAIN + JSON.generate(Tamoz::Core.canonical(definition))
        )}"
      end

      def validate!(
        spec_id:, version:, schema_id:, risk_class:,
        max_confidence:, freshness_seconds:, deadline_seconds:,
        debounce_seconds:, cooldown_seconds:, max_cost_estimate:,
        late_data_policy:, idle_after_seconds:
      )
        unless spec_id.is_a?(String) && !spec_id.empty? && spec_id.bytesize <= 255
          raise Tamoz::ConfigurationError, "spec_id must be a bounded string"
        end
        unless version.is_a?(Integer) && version >= 1
          raise Tamoz::ConfigurationError, "version must be a positive integer"
        end
        unless schema_id.is_a?(String) && !schema_id.empty?
          raise Tamoz::ConfigurationError, "schema_id must be a non-empty string"
        end
        unless RISK_CLASSES.include?(risk_class)
          raise Tamoz::ConfigurationError, "risk_class must be one of #{RISK_CLASSES.inspect}"
        end
        unless max_confidence.is_a?(Numeric) && max_confidence.between?(0.0, 1.0)
          raise Tamoz::ConfigurationError, "max_confidence must be in [0.0, 1.0]"
        end
        unless LATE_DATA_POLICIES.include?(late_data_policy)
          raise Tamoz::ConfigurationError, "late_data_policy must be one of #{LATE_DATA_POLICIES.inspect}"
        end
        [freshness_seconds, deadline_seconds, debounce_seconds,
         cooldown_seconds, max_cost_estimate, idle_after_seconds].each do |value|
          unless value.is_a?(Integer) && value.positive?
            raise Tamoz::ConfigurationError, "spec durations/costs must be positive integers"
          end
        end

        {
          spec_id: spec_id.freeze, version:, schema_id: schema_id.freeze,
          risk_class:, max_confidence:, freshness_seconds:,
          deadline_seconds:, debounce_seconds:, cooldown_seconds:,
          max_cost_estimate:, late_data_policy:, idle_after_seconds:
        }.freeze
      end
    end

    # P14-C (plan §6/C7) — an admitted SituationSnapshot: bounded and
    # content-addressed. It carries the exact Situation version, the evidence
    # and uncertainty, the permitted risk class, and the canonical hash. The
    # bridge binds the accepted plan to this snapshot digest (invariant 49);
    # a superseded episode's late Decision dies on the snapshot-digest
    # mismatch (freshness check).
    class SituationSnapshot
      DIGEST_DOMAIN = "tamoz.stream.situation_snapshot.v1\n"

      attr_reader :situation_id, :situation_version, :evidence, :uncertainty,
                  :risk_class, :deadline, :created_at, :snapshot_digest

      def initialize(situation_id:, situation_version:, evidence:, uncertainty:,
                     risk_class:, deadline:, created_at:, snapshot_digest: nil)
        @situation_id = situation_id
        @situation_version = situation_version
        @evidence = Tamoz::Core.deep_freeze(evidence)
        @uncertainty = uncertainty
        @risk_class = risk_class
        @deadline = deadline
        @created_at = created_at
        @snapshot_digest = snapshot_digest || compute_digest
      end

      def to_h
        {
          "situation_id" => situation_id,
          "situation_version" => situation_version,
          "evidence" => evidence,
          "uncertainty" => uncertainty,
          "risk_class" => risk_class.to_s,
          "deadline" => deadline,
          "created_at" => created_at,
          "snapshot_digest" => snapshot_digest
        }
      end

      private

      def compute_digest
        body = {
          "situation_id" => situation_id,
          "situation_version" => situation_version,
          "evidence" => evidence,
          "uncertainty" => uncertainty,
          "risk_class" => risk_class.to_s,
          "deadline" => deadline
        }
        "sha256:#{Digest::SHA256.hexdigest(
          DIGEST_DOMAIN + JSON.generate(Tamoz::Core.canonical(body))
        )}"
      end
    end
  end
end
