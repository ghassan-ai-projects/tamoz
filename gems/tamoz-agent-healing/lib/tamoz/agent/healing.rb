# frozen_string_literal: true

module Tamoz
  module Agent
    # P12 bounded self-healing (work packages P12-HD / H1 / H2).
    #
    # This module implements the typed failure contract, classification and
    # abstention, the immutable rule contract, and the reviewed remediation
    # protocol. Compensation execution, the durable circuit record, the escalation
    # issue record, and the promotion lifecycle are P12-H3/H4 and reach this code
    # only through `Healing::Seams`.
    #
    # Load-time note: `healing` is required by `tamoz/agent`, which already loads
    # `tamoz/tools` (the configured-check machinery the oracle reuses). Nothing
    # here loads RubyLLM or `tamoz-evals`, so the dependency-isolation test stays
    # green — the semantic critic is an INJECTED callable, never a model client.
    module Healing
      # Invariant 18 allowlist. Only these record kinds are revivable, and each
      # one's `from_h` checks its `format_version` before reading any other field.
      RECORD_KINDS = {
        "failure" => FailureRecord,
        "rule" => HealingRule
      }.freeze

      module_function

      # The single allowlisted entry point for reviving a durable healing record.
      # An unknown kind fails before the payload is inspected; an unsupported
      # version fails inside `from_h`, again before a partial object exists.
      def load_record!(kind, payload)
        klass = RECORD_KINDS.fetch(String(kind)) do
          raise CheckpointCorruptionError,
                "unknown healing record kind #{kind.inspect}"
        end
        klass.from_h(payload)
      end

      # P12 migration semantics. A session, plan, or effect record written before
      # P12 carries no healing pin. `LEGACY_HEALING_PIN` is the sentinel filled at
      # load (the exact P9 `LEGACY_SKILL_EPOCH` / P17 `egress_pin` pattern):
      # absent means "no healing rule set was bound", which is the legacy
      # behavior — no classification, no remediation, no new prompt bytes.
      LEGACY_HEALING_PIN = {}.freeze

      # The canonical pin for an enabled rule set: {rule_id => "version:digest"}.
      # `{}` is both "pre-P12" and "P12 with healing disabled" — deliberately the
      # same state, exactly as `egress_pin` treats "no egress declaration".
      def pin_for(rules)
        rules.to_h do |rule|
          [rule.rule_id, "#{rule.version}:#{rule.contract_digest}"]
        end.sort.to_h.freeze
      end
    end
  end
end
