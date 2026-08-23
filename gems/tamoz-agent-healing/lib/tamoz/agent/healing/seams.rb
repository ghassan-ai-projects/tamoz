# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # P12-HD/H1/H2 owns classification, the rule contract, and the remediation
      # protocol. The DURABLE circuit record (DR-2 §2: one record type, four
      # scopes), the escalation issue record, compensation execution, and the
      # promotion lifecycle belong to P12-H3/H4.
      #
      # This file defines the narrow, documented INJECTION POINTS those need, with
      # in-memory / no-op defaults so the protocol is complete and testable today
      # and the durable implementations drop in without touching the protocol.
      #
      # Nothing here is a second engine: `MemoryCircuitStore` intentionally mirrors
      # the interface of the already-shipped `Tamoz::Mcp::MemoryCircuitStore` (P10
      # slice 3), so the DR-2 durable record can satisfy both call sites at once.
      module Seams
        # --- circuit -----------------------------------------------------------
        #
        # Interface (identical to `Tamoz::Mcp::MemoryCircuitStore`, plus `scope`):
        #
        #   #scope                                     -> String
        #   #open?                                     -> true|false
        #   #failures                                  -> Integer
        #   #record_failure(kind:, context: nil)       -> :closed|:degraded|:open
        #   #record_success                            -> :closed|:degraded|:open
        #   #reset(evidence: nil)                      -> :closed
        #   #reset_evidence                            -> Object|nil
        #
        # Builder B replaces this with the durable DR-2 record (Store namespace
        # `tamoz.circuit.<scope>`, CAS via `Store#put if_version:`). The protocol
        # only ever calls `open?`, `record_failure`, and `record_success`; it never
        # calls `reset` — reset requires owner evidence and a reviewed plan, which
        # is H3's contract. `Scope.refuse_in_band!` guards `reset` here so an
        # in-band remediation cannot reset its own circuit even with this default.
        class MemoryCircuitStore
          DEFAULT_THRESHOLD = 2

          attr_reader :scope, :threshold

          def initialize(scope:, threshold: DEFAULT_THRESHOLD)
            unless threshold.is_a?(Integer) && threshold >= 1
              raise HealingPolicyError, "circuit threshold must be an integer >= 1"
            end

            @scope = String(scope).dup.freeze
            @threshold = threshold
            @failures = 0
            @state = :closed
            @conditions = []
            @reset_evidence = nil
            @mutex = Mutex.new
          end

          def record_failure(kind: :verification, context: nil)
            @mutex.synchronize do
              @failures += 1
              @conditions << {"kind" => kind.to_s, "context" => context}.freeze
              @state = @failures >= @threshold ? :open : :degraded
              @state
            end
          end

          def record_success
            @mutex.synchronize do
              unless @state == :open
                @failures = 0
                @state = :closed
              end
              @state
            end
          end

          def open? = @mutex.synchronize { @state == :open }
          def failures = @mutex.synchronize { @failures }
          def conditions = @mutex.synchronize { @conditions.dup.freeze }
          def reset_evidence = @mutex.synchronize { @reset_evidence }

          # Design §10: time alone never resets a circuit; reset requires owner
          # evidence, a reviewed plan, and normally a new rule version. The
          # evidence CONTENT gate is H3's; the invariant-34 refusal is ours.
          def reset(evidence: nil)
            Scope.refuse_in_band!("circuit reset", error_class: SelfPromotionError)
            if evidence.nil?
              raise SelfPromotionError,
                    "a circuit reset requires owner evidence; time alone never resets it"
            end

            @mutex.synchronize do
              @failures = 0
              @state = :closed
              @reset_evidence = evidence
              @state
            end
          end
        end

        # --- escalation --------------------------------------------------------
        #
        # Interface:
        #
        #   #record(payload) -> String  (the escalation id)
        #   #records         -> [Hash]  (test/inspection only)
        #
        # The PAYLOAD shape the protocol emits is the design §10 issue contract:
        #
        #   {"failure_fingerprint", "failure_digest", "rule_id", "rule_version",
        #    "rule_digest", "lifecycle_mode", "attempts", "terminal_state",
        #    "classification", "preflight", "verification", "compensation",
        #    "containment", "transitions", "before_digest", "after_digest",
        #    "recommended_next_action"}
        #
        # Builder B replaces this with the durable owned issue record (Store
        # namespace `tamoz.escalations.<id>`) and adds the C7/P2 completeness
        # cross-check of the compensation effect's journal receipt digest. The
        # protocol already emits `compensation` with the receipt it was handed, so
        # the cross-check has both sides available without a protocol change.
        class NullEscalationSink
          def initialize
            @records = []
            @mutex = Mutex.new
          end

          def record(payload)
            @mutex.synchronize do
              id = "escalation.#{@records.length + 1}"
              @records << payload.merge("escalation_id" => id).freeze
              id
            end
          end

          def records = @mutex.synchronize { @records.dup.freeze }
          def last = @mutex.synchronize { @records.last }
        end

        # --- compensation ------------------------------------------------------
        #
        # Interface:
        #
        #   #compensate(rule:, record:, classification:, effect_identity:)
        #     -> {"status" => "succeeded"|"failed"|"contained",
        #         "receipt_digest" => String|nil, "detail" => String|nil}
        #
        # The DEFAULT never claims a rollback it did not perform (design §9,
        # irreversible row): it returns `contained` with no receipt digest. That
        # deliberately keeps the terminal state honest until H3 lands real
        # compensation — a default that returned "succeeded" would manufacture the
        # exact concealment the phase's hard-zero gate forbids.
        class ContainOnlyCompensation
          def compensate(rule:, record:, classification:, effect_identity:)
            {
              "status" => "contained",
              "receipt_digest" => nil,
              "kind" => rule.compensation.fetch("kind"),
              "detail" => "no compensation executor is installed; evidence preserved " \
                          "and the effect is contained, not rolled back",
              "effect_operation" => effect_identity && effect_identity["operation"],
              "target_resource" => record.target_resource,
              "category" => classification.category.to_s
            }.freeze
          end
        end

        # --- promotion ---------------------------------------------------------
        #
        # Interface:
        #
        #   #promotion_for(rule) -> nil | {"contract_digest" =>, "mode" =>,
        #                                  "evidence_digest" =>, "approver" =>}
        #
        # Invariant 34: `lifecycle_mode` transitions are written only by
        # `tamoz-evals`, digest-bound to eval evidence, and the runtime verifies on
        # rule LOAD that the mode is backed by a matching promotion record. The
        # default has no records, so any rule past `shadow` is refused at load —
        # fail-closed until H4 supplies the real registry.
        class NullPromotionRegistry
          def promotion_for(_rule) = nil
        end
      end
    end
  end
end
