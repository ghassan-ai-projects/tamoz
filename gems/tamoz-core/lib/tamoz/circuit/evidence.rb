# frozen_string_literal: true

module Tamoz
  module Circuit
    # DR-2 §5 — reset authority, with the plan's per-scope evidence weight.
    #
    # `closed → open` needs no gate at all (circuits must open automatically).
    # `open → closed` accepts ONLY the authority named in the scope's
    # `reset_authority`, and the gate lives on the RECORD WRITE, so no in-process
    # caller can bypass it by calling a different method.
    #
    # A refusal is a POLICY VIOLATION, not a repairable value (invariant 17):
    # it propagates as `Tamoz::CircuitPolicyError` and is never converted into a
    # retryable result. Refusals leave the circuit open.
    module Evidence
      IDENTITY_KEYS = %w[actor authority].freeze
      COMMAND_KEYS = %w[operator_command_digest command_digest].freeze
      PLAN_KEYS = %w[plan_digest eval_digest].freeze

      module_function

      # Validates `evidence` for `scope` and returns the frozen record that is
      # written with the reset. Raises `Tamoz::CircuitPolicyError` otherwise.
      def validate!(evidence, scope:)
        rule = Registry.fetch(scope).evidence_rule
        unless evidence.is_a?(Hash)
          refuse!("evidence must be a mapping naming the authority and its command or plan")
        end

        normalized = Circuit.digestable(evidence)
        case rule
        when "caller_command" then validate_caller_command!(normalized)
        when "operator_command" then validate_operator_command!(normalized, scope)
        when "reviewed_plan" then validate_reviewed_plan!(normalized)
        when "owner_or_evals" then validate_owner_or_evals!(normalized)
        else
          refuse!("the circuit scope declares an unknown reset evidence rule")
        end

        Tamoz::Core.deep_freeze(normalized)
      end

      # The digest recorded on the record. The evidence itself stays with the
      # caller; only its digest crosses the durable boundary.
      def digest(evidence)
        Circuit.digest_of(evidence, domain: EVIDENCE_DIGEST_DOMAIN)
      end

      # --- per-scope evidence weight ----------------------------------------

      # `:server` (DR-2 §5) — the P10 §8 caller-command contract: an operator
      # identity plus the command record it acted on. Deliberately NOT a plan
      # review: widening this scope's authority to a reviewed plan would change
      # the landed P10 contract.
      def validate_caller_command!(evidence)
        unless present_identity(evidence)
          refuse!("a server-scope reset requires the operator identity that issued it")
        end
        unless present_value(evidence, COMMAND_KEYS)
          refuse!("a server-scope reset requires the operator command record it acted on")
        end
        true
      end

      # `:egress` (DR-2 §5) — the operator command record, with a well-formed
      # command digest. The capability itself can never satisfy this.
      def validate_operator_command!(evidence, scope)
        authority = Registry.fetch(scope).reset_authority
        unless evidence["authority"] == authority
          refuse!(
            "an egress-scope reset requires authority #{authority.inspect} " \
            "with the operator command record"
          )
        end
        unless digest_value(evidence, %w[operator_command_digest])
          refuse!("an egress-scope reset requires a well-formed operator command digest")
        end
        true
      end

      # `rule_target` (DR-2 §5) — `tamoz-evals` or a human-approved plan, with
      # plan/eval evidence, and normally a new rule version (required here: a
      # rule that reopens its own circuit without a version bump is exactly the
      # self-promotion the design forbids).
      def validate_reviewed_plan!(evidence)
        unless %w[tamoz-evals human_approved_plan].include?(evidence["authority"])
          refuse!(
            "a rule_target reset requires authority \"tamoz-evals\" or " \
            "\"human_approved_plan\""
          )
        end
        unless digest_value(evidence, PLAN_KEYS)
          refuse!("a rule_target reset requires a well-formed plan or eval digest")
        end
        unless present_value(evidence, %w[rule_version])
          refuse!("a rule_target reset requires the new rule version")
        end
        true
      end

      # `schedule` (DR-2 §5) — the schedule owner or `tamoz-evals`, with eval or
      # command evidence.
      def validate_owner_or_evals!(evidence)
        unless %w[owner tamoz-evals].include?(evidence["authority"])
          refuse!("a schedule reset requires authority \"owner\" or \"tamoz-evals\"")
        end
        unless digest_value(evidence, PLAN_KEYS + COMMAND_KEYS)
          refuse!("a schedule reset requires a well-formed eval or command digest")
        end
        true
      end

      # --- helpers ----------------------------------------------------------

      def present_identity(evidence)
        present_value(evidence, IDENTITY_KEYS)
      end

      def present_value(evidence, keys)
        keys.any? do |key|
          value = evidence[key]
          value.is_a?(String) && !value.strip.empty?
        end
      end

      def digest_value(evidence, keys)
        keys.any? do |key|
          value = evidence[key]
          value.is_a?(String) && DIGEST_PATTERN.match?(value)
        end
      end

      def refuse!(reason)
        raise CircuitPolicyError, "the circuit reset was refused: #{reason}"
      end
    end
  end
end
