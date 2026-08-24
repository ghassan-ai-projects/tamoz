# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    module Healing
      # P12 §3 / SELF_HEALING_DESIGN §3 — the typed failure contract.
      #
      # The design's field list, verbatim, in order:
      #
      #   format_version
      #   failure_code and category
      #   operation/tool and target resource
      #   expected and observed state digests
      #   effect state: not_attempted | running | completed | unknown
      #   graph/task/execution ids
      #   policy and behavior versions
      #   retryability evidence
      #   trusted context plus untrusted raw message reference
      #
      # Two properties are load-bearing and are asserted by tests rather than
      # documented and hoped for:
      #
      # 1. **Free-form text is never the sole mutation trigger.** The untrusted
      #    provider message is NOT stored here. Only a REFERENCE to it is —
      #    `untrusted_message_ref`, an opaque {digest:, source:, bytes:} handle.
      #    `#typed_signal` is the ONLY view the classifier is given, and it
      #    excludes the reference entirely, so no classification path can read
      #    provider prose. `Classification::LegacyTextAdapter` may *propose* from
      #    text, but its proposal is capped at a non-mutating action family.
      #
      # 2. **Invariant 18.** `FORMAT_VERSION` is checked in `from_h` BEFORE any
      #    other field is read, and an unsupported version raises
      #    `CheckpointVersionError` — never a partial load. The allowlist is
      #    `Healing::RECORD_KINDS`, applied by `Healing.load_record!`.
      class FailureRecord < Data.define(
        :format_version, :failure_code, :category, :operation, :tool,
        :target_resource, :expected_digest, :observed_digest, :effect_state,
        :graph_id, :task_id, :execution_id, :policy_version, :behavior_version,
        :retryability, :capability_absent, :trusted_context,
        :untrusted_message_ref, :observed_at_ms
      )
        FORMAT_VERSION = 1
        DIGEST_DOMAIN = "tamoz.agent.healing.failure_record"
        MAX_ID_BYTES = 256
        MAX_CONTEXT_KEYS = 32

        # Design §3, in design order. Twelve categories; the set is closed.
        CATEGORIES = %i[
          transient_pre_dispatch
          stale_precondition
          dependency_unavailable
          malformed_recoverable_output
          resource_exhausted
          policy_denied
          effect_unknown
          verification_failed
          derived_state_corrupt
          durable_state_corrupt
          programmer_error
          unknown
        ].freeze

        EFFECT_STATES = %i[not_attempted running completed unknown].freeze

        # P12 §3 (C10): **FIVE** never-mutate classes. FOUR of them are
        # categories; the fifth — capability absence — is a CROSS-CUTTING typed
        # predicate that can accompany any category, which is exactly why the
        # count is five and not four. Design §3: "Policy denial, durable
        # corruption, programmer error, unknown classification, and capability
        # absence never trigger automatic mutation."
        NEVER_MUTATE_CATEGORIES = %i[
          policy_denied durable_state_corrupt programmer_error unknown
        ].freeze
        NEVER_MUTATE_CLASSES = (
          NEVER_MUTATE_CATEGORIES.map { |name| [:category, name] } +
          [[:predicate, :capability_absent]]
        ).freeze

        # The retryability evidence keys the design requires. `pre_dispatch` and
        # `effect_safety` are typed booleans/symbols produced by the framework —
        # never derived from provider prose.
        RETRYABILITY_KEYS = %w[pre_dispatch effect_safety source].freeze
        EFFECT_SAFETIES = %w[read_only idempotent transactional reconcilable unsafe].freeze

        def initialize(
          format_version: FORMAT_VERSION,
          failure_code:,
          category:,
          operation:,
          tool: nil,
          target_resource: nil,
          expected_digest: nil,
          observed_digest: nil,
          effect_state: :not_attempted,
          graph_id: nil,
          task_id: nil,
          execution_id: nil,
          policy_version:,
          behavior_version:,
          retryability: {},
          capability_absent: false,
          trusted_context: {},
          untrusted_message_ref: nil,
          observed_at_ms: 0
        )
          unless format_version == FORMAT_VERSION
            raise HealingPolicyError,
                  "FailureRecord format_version #{format_version.inspect} is not supported"
          end
          unless capability_absent == true || capability_absent == false
            raise HealingPolicyError, "capability_absent must be true or false"
          end
          unless observed_at_ms.is_a?(Integer) && !observed_at_ms.negative?
            raise HealingPolicyError, "observed_at_ms must be a non-negative integer"
          end

          super(
            format_version:,
            failure_code: validate_id(failure_code, "failure_code"),
            category: validate_member(category, CATEGORIES, "category"),
            operation: validate_id(operation, "operation"),
            tool: tool.nil? ? nil : validate_id(tool, "tool"),
            target_resource: target_resource.nil? ? nil : validate_id(target_resource, "target_resource"),
            expected_digest: validate_optional_digest(expected_digest, "expected_digest"),
            observed_digest: validate_optional_digest(observed_digest, "observed_digest"),
            effect_state: validate_member(effect_state, EFFECT_STATES, "effect_state"),
            graph_id: graph_id.nil? ? nil : validate_id(graph_id, "graph_id"),
            task_id: task_id.nil? ? nil : validate_id(task_id, "task_id"),
            execution_id: execution_id.nil? ? nil : validate_id(execution_id, "execution_id"),
            policy_version: validate_id(policy_version, "policy_version"),
            behavior_version: validate_id(behavior_version, "behavior_version"),
            retryability: Tamoz::Core.deep_freeze(validate_retryability(retryability)),
            capability_absent:,
            trusted_context: Tamoz::Core.deep_freeze(validate_trusted_context(trusted_context)),
            untrusted_message_ref: untrusted_message_ref.nil? ? nil : Tamoz::Core.deep_freeze(
              validate_message_ref(untrusted_message_ref)
            ),
            observed_at_ms:
          )
        end

        # P12 §3 (C10). True when this failure belongs to one of the FIVE
        # never-mutate classes. A `true` here forbids automatic mutation
        # regardless of what any rule, adapter, or model proposes.
        def never_mutate?
          NEVER_MUTATE_CATEGORIES.include?(category) || capability_absent
        end

        # The name of the never-mutate class that applies, or nil.
        def never_mutate_class
          return :capability_absent if capability_absent
          return category if NEVER_MUTATE_CATEGORIES.include?(category)

          nil
        end

        # THE ONLY view a classifier receives. Deliberately excludes
        # `untrusted_message_ref`: a classification can never be a function of
        # provider prose (design §3). Frozen, so a classifier cannot smuggle
        # state back either.
        def typed_signal
          Tamoz::Core.deep_freeze(
            {
              "failure_code" => failure_code,
              "category" => category.to_s,
              "operation" => operation,
              "tool" => tool,
              "target_resource" => target_resource,
              "expected_digest" => expected_digest,
              "observed_digest" => observed_digest,
              "effect_state" => effect_state.to_s,
              "capability_absent" => capability_absent,
              "retryability" => retryability,
              "policy_version" => policy_version,
              "behavior_version" => behavior_version,
              "trusted_context" => trusted_context
            }
          )
        end

        # Design §10 "the same fingerprint recurs three times in one run". The
        # fingerprint is typed-only, so a changed provider message does not make a
        # recurring failure look new.
        def fingerprint
          Tamoz::Core.digest(
            "#{DIGEST_DOMAIN}.fingerprint.v1\n",
            {
              "failure_code" => failure_code,
              "category" => category.to_s,
              "operation" => operation,
              "tool" => tool,
              "target_resource" => target_resource,
              "capability_absent" => capability_absent
            }
          )
        end

        def digest
          Tamoz::Core.digest("#{DIGEST_DOMAIN}.v1\n", to_h)
        end

        def pre_dispatch? = retryability["pre_dispatch"] == true
        def effect_safety = retryability["effect_safety"]
        def effect_unknown? = effect_state == :unknown

        def to_h
          {
            "format_version" => format_version,
            "failure_code" => failure_code,
            "category" => category.to_s,
            "operation" => operation,
            "tool" => tool,
            "target_resource" => target_resource,
            "expected_digest" => expected_digest,
            "observed_digest" => observed_digest,
            "effect_state" => effect_state.to_s,
            "graph_id" => graph_id,
            "task_id" => task_id,
            "execution_id" => execution_id,
            "policy_version" => policy_version,
            "behavior_version" => behavior_version,
            "retryability" => retryability,
            "capability_absent" => capability_absent,
            "trusted_context" => trusted_context,
            "untrusted_message_ref" => untrusted_message_ref,
            "observed_at_ms" => observed_at_ms
          }
        end

        # Invariant 18. The version gate runs FIRST; an unsupported version fails
        # before any other field is read, so a newer record can never be partially
        # loaded into an older shape.
        def self.from_h(hash)
          unless hash.is_a?(Hash)
            raise CheckpointCorruptionError, "FailureRecord must be an object"
          end

          version = hash["format_version"]
          unless version == FORMAT_VERSION
            raise CheckpointVersionError,
                  "FailureRecord format_version #{version.inspect} is not supported"
          end

          new(
            format_version: version,
            failure_code: hash.fetch("failure_code"),
            category: hash.fetch("category").to_sym,
            operation: hash.fetch("operation"),
            tool: hash["tool"],
            target_resource: hash["target_resource"],
            expected_digest: hash["expected_digest"],
            observed_digest: hash["observed_digest"],
            effect_state: hash.fetch("effect_state").to_sym,
            graph_id: hash["graph_id"],
            task_id: hash["task_id"],
            execution_id: hash["execution_id"],
            policy_version: hash.fetch("policy_version"),
            behavior_version: hash.fetch("behavior_version"),
            retryability: hash.fetch("retryability", {}),
            capability_absent: hash.fetch("capability_absent", false),
            trusted_context: hash.fetch("trusted_context", {}),
            untrusted_message_ref: hash["untrusted_message_ref"],
            observed_at_ms: hash.fetch("observed_at_ms", 0)
          )
        rescue KeyError => error
          raise CheckpointCorruptionError, "FailureRecord is incomplete: #{error.message}"
        end

        # Builds the untrusted-message REFERENCE from raw provider text without
        # ever storing the text. The digest lets an operator correlate the record
        # with the raw log; nothing in the classification path reads it.
        def self.message_ref(raw, source:)
          text = String(raw)
          {
            "digest" => "sha256:#{Digest::SHA256.hexdigest(text)}",
            "source" => String(source).dup.freeze,
            "bytes" => text.bytesize
          }
        end

        private

        def validate_id(value, name)
          SafeText.normalize(
            value, name:, max_bytes: MAX_ID_BYTES, error_class: HealingPolicyError
          )
        end

        def validate_member(value, set, name)
          unless set.include?(value)
            raise HealingPolicyError,
                  "#{name} must be one of #{set.map(&:inspect).join(", ")}"
          end

          value
        end

        def validate_optional_digest(value, name)
          return nil if value.nil?

          unless value.is_a?(String) && value.match?(/\A[a-z0-9]+:[A-Za-z0-9+\/=_-]+\z/)
            raise HealingPolicyError, "#{name} must be an algorithm-qualified digest"
          end

          value.dup.freeze
        end

        def validate_retryability(value)
          unless value.is_a?(Hash)
            raise HealingPolicyError, "retryability evidence must be an object"
          end

          unknown = value.keys.map(&:to_s) - RETRYABILITY_KEYS
          unless unknown.empty?
            raise HealingPolicyError,
                  "retryability evidence does not accept #{unknown.sort.inspect}"
          end
          if value.key?("pre_dispatch") &&
             !(value["pre_dispatch"] == true || value["pre_dispatch"] == false)
            raise HealingPolicyError, "retryability pre_dispatch must be true or false"
          end
          if value.key?("effect_safety") &&
             !EFFECT_SAFETIES.include?(value["effect_safety"].to_s)
            raise HealingPolicyError,
                  "retryability effect_safety must be one of #{EFFECT_SAFETIES.inspect}"
          end

          value
        end

        # Trusted context is Tamoz-generated structured evidence. It is bounded and
        # rejects nested free text beyond an id-sized budget, so it cannot become a
        # smuggling channel for the provider message the record deliberately omits.
        def validate_trusted_context(value)
          unless value.is_a?(Hash)
            raise HealingPolicyError, "trusted_context must be an object"
          end
          if value.length > MAX_CONTEXT_KEYS
            raise HealingPolicyError,
                  "trusted_context exceeds #{MAX_CONTEXT_KEYS} keys"
          end
          value.each do |key, entry|
            SafeText.normalize(
              key, name: "trusted_context key", max_bytes: MAX_ID_BYTES,
              error_class: HealingPolicyError
            )
            case entry
            when String
              SafeText.normalize(
                entry, name: "trusted_context #{key}", max_bytes: MAX_ID_BYTES,
                error_class: HealingPolicyError
              )
            when Numeric, true, false, nil
              nil
            else
              raise HealingPolicyError,
                    "trusted_context #{key} must be a bounded scalar"
            end
          end
          value
        end

        def validate_message_ref(value)
          unless value.is_a?(Hash) && value.key?("digest") && value.key?("source")
            raise HealingPolicyError,
                  "untrusted_message_ref must carry digest and source"
          end
          if value.key?("text") || value.key?("message") || value.key?("body")
            raise HealingPolicyError,
                  "untrusted_message_ref is a REFERENCE; it must not carry the raw text"
          end
          unless value.fetch("digest").is_a?(String) && !value.fetch("digest").empty?
            raise HealingPolicyError, "untrusted_message_ref digest must be a non-empty string"
          end

          value
        end
      end
    end
  end
end
