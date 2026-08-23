# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # Invariant 34 enforcement primitive.
      #
      # "A rule may not change its own matcher, oracle, budgets, authority, or
      # circuit" cannot be enforced by trusting a caller-supplied `actor:` string —
      # a remediation step can write any string it likes. So the remediation
      # protocol wraps EVERY in-band phase (plan, review, preflight, execute,
      # verify) in `Healing::Scope.in_band`, and `RuleRegistry`/`PromotionGate`
      # refuse any lifecycle write, amendment of a self-protected field, or circuit
      # reset while that flag is set — regardless of the claimed actor.
      #
      # The flag is FIBER-local, so a concurrent unrelated task is unaffected, and
      # it is depth-counted so nesting cannot leak the guard off early. `ensure`
      # restores it even when the remediation raises.
      module Scope
        KEY = :tamoz_agent_healing_in_band_depth

        module_function

        def in_band(&block)
          raise HealingContractError, "Healing::Scope.in_band requires a block" unless block

          Thread.current[KEY] = depth + 1
          begin
            block.call
          ensure
            Thread.current[KEY] = depth - 1
          end
        end

        def in_band? = depth.positive?

        def depth
          value = Thread.current[KEY]
          value.is_a?(Integer) ? value : 0
        end

        # Raise when called from inside a remediation. `what` names the refused
        # operation so the escalation record can carry it without parsing prose.
        def refuse_in_band!(what, error_class: SelfModificationError)
          return unless in_band?

          raise error_class,
                "#{what} is refused inside a remediation: a rule may not change " \
                "its own matcher, oracle, budgets, authority, circuit, or lifecycle " \
                "(invariant 34)"
        end
      end
    end
  end
end
