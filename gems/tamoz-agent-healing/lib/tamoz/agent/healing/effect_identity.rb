# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # SELF_HEALING_DESIGN §7 — the stable remediation key.
      #
      #   original trace + original tool/effect id + rule id/version + remediation step
      #
      # The key is the `operation` handed to the EXISTING effect journal through
      # `EffectDispatcher.run`; healing adds no second effect model. Two properties
      # matter and are tested:
      #
      # * determinism — same inputs produce the same key on every run, process, and
      #   locale (the canonical JSON sorter is byte-stable and the digest is over
      #   an ASCII-safe domain string);
      # * separation — changing ANY component changes the key, so a retry under a
      #   new rule version is a NEW effect rather than a silent reuse of an old
      #   receipt.
      module EffectIdentity
        DOMAIN = "tamoz.agent.healing.effect_identity.v1"

        module_function

        # Returns the operation string. Prefixed with `healing.` so a remediation
        # effect is never confused with the original tool effect in the journal.
        def operation(
          original_trace_id:,
          original_effect_id:,
          rule_id:,
          rule_version:,
          remediation_step:,
          domain: DOMAIN
        )
          components = [
            String(original_trace_id),
            String(original_effect_id),
            String(rule_id),
            Integer(rule_version),
            String(remediation_step)
          ]
          components.each_with_index do |value, index|
            if value.is_a?(String) && value.empty?
              raise HealingContractError,
                    "effect identity component #{index} must not be empty"
            end
          end

          "healing.#{Tamoz::Core.digest("#{domain}\n", components).delete_prefix('sha256:')}"
        end

        # The full, inspectable identity — what the transition log records so an
        # auditor can recompute the key without the source that produced it.
        def describe(**arguments)
          {
            "domain" => arguments.fetch(:domain, DOMAIN),
            "original_trace_id" => String(arguments.fetch(:original_trace_id)),
            "original_effect_id" => String(arguments.fetch(:original_effect_id)),
            "rule_id" => String(arguments.fetch(:rule_id)),
            "rule_version" => Integer(arguments.fetch(:rule_version)),
            "remediation_step" => String(arguments.fetch(:remediation_step)),
            "operation" => operation(**arguments)
          }.freeze
        end
      end
    end
  end
end
