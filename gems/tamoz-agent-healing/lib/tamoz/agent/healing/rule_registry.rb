# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # The enabled-rule set and the invariant-34 guard rail.
      #
      # Two refusals live here, and both are proven by EXECUTING the attempt rather
      # than by inspection:
      #
      # * `#amend` refuses any change to a `SELF_PROTECTED_FIELDS` field made from
      #   inside a remediation (`Healing::Scope.in_band?`), regardless of the
      #   `actor:` string the caller supplies — a remediation step can write any
      #   string, so the guard cannot be a string comparison. Outside a remediation,
      #   a self-protected change still needs a reviewed diff plus human approval
      #   for a mutation-capable rule (C7/P1).
      # * `#write_lifecycle_mode` refuses in-band writes outright, and out-of-band
      #   writes without a promotion record digest-bound to the rule's
      #   `contract_digest` (invariant 34 — "rules cannot promote or reset
      #   themselves").
      #
      # Storage is a plain in-memory map. Rules are frozen `Data`, so this is a
      # versioned append-only index, not a mutable store. Builder B/H4 can back it
      # with the existing SQLite Store (`Store#put ... if_version:` CAS) without
      # changing any method signature — nothing here assumes memory residency
      # beyond `@versions`.
      class RuleRegistry
        # Loading a rule past `shadow` requires a promotion record. Below that the
        # rule is disabled/observational anyway (design §4: "Rules default to
        # disabled/shadow").
        def initialize(promotion_registry: Seams::NullPromotionRegistry.new)
          @promotion_registry = promotion_registry
          @versions = Hash.new { |hash, key| hash[key] = [] }
          @mutex = Mutex.new
        end

        # Registers one rule VERSION. Rejects a duplicate version and a
        # non-monotonic version, so history is append-only.
        def register(rule)
          unless rule.is_a?(HealingRule)
            raise HealingContractError, "register expects a HealingRule"
          end

          verify_lifecycle_backing!(rule)
          @mutex.synchronize do
            history = @versions[rule.rule_id]
            assert_unique_version!(history, rule)
            assert_monotonic_version!(history, rule)

            history << rule
            rule
          end
        end

        def fetch(rule_id, version: nil)
          @mutex.synchronize do
            history = @versions[String(rule_id)]
            raise HealingPolicyError, "no rule #{rule_id.inspect}" if history.empty?

            if version.nil?
              history.last
            else
              history.find { |rule| rule.version == version } ||
                raise(HealingPolicyError, "no rule #{rule_id.inspect} version #{version}")
            end
          end
        end

        def versions(rule_id) = @mutex.synchronize { @versions[String(rule_id)].dup.freeze }
        def rule_ids = @mutex.synchronize { @versions.keys.sort.freeze }

        # Invariant 34. Produces a NEW rule version; never mutates an existing one.
        #
        # `actor:` is RECORDED, not TRUSTED: the in-band guard fires first and is
        # independent of it. `approval:` must be a human-gate string for any change
        # to a self-protected field on a mutation-capable rule, and `reviewed_diff:`
        # must name the fields it changes so a reviewer's acceptance is bound to
        # the actual delta.
        def amend(rule_id:, updates:, actor:, approval: nil, reviewed_diff: nil)
          current = fetch(rule_id)
          changed = changed_self_protected_fields(current, updates)

          unless changed.empty?
            Scope.refuse_in_band!(
              "amending rule #{rule_id} field(s) #{self_protected_field_list(changed)}"
            )
            assert_reviewed_diff!(current, changed, approval:, reviewed_diff:)
          end

          next_version = current.version + 1
          amended = HealingRule.new(
            **current.to_init_hash.merge(updates).merge(version: next_version)
          )
          register(amended)
          amended
        end

        # Invariant 34, second half. Only `tamoz-evals` writes a lifecycle mode,
        # and only with a promotion record bound to this exact rule contract.
        def write_lifecycle_mode(rule_id:, mode:, promotion:, actor:)
          Scope.refuse_in_band!(
            "lifecycle write to rule #{rule_id}", error_class: SelfPromotionError
          )
          current = fetch(rule_id)
          assert_promotion_authorizes!(rule_id:, current:, mode:, promotion:)

          promoted = HealingRule.new(
            **current.to_init_hash.merge(
              version: current.version + 1,
              lifecycle_mode: mode.to_sym,
              promotion_evidence: promotion
            )
          )
          register(promoted)
          promoted
        end

        # Fail-closed load gate: a mode past `shadow` needs backing evidence.
        def verify_lifecycle_backing!(rule)
          return if HealingRule::SELF_SERVE_MODES.include?(rule.lifecycle_mode)

          promotion = @promotion_registry.promotion_for(rule)
          unless promotion.is_a?(Hash) &&
                 promotion["contract_digest"] == rule.contract_digest &&
                 promotion["mode"].to_s == rule.lifecycle_mode.to_s
            raise SelfPromotionError,
                  "rule #{rule.rule_id} claims lifecycle mode " \
                  "#{rule.lifecycle_mode.inspect} without a matching promotion record"
          end
        end

        private

        def assert_unique_version!(history, rule)
          return unless history.any? { |existing| existing.version == rule.version }

          raise HealingPolicyError,
                "rule #{rule.rule_id} version #{rule.version} is already registered; " \
                "a rule version is immutable"
        end

        def assert_monotonic_version!(history, rule)
          return unless history.any? && rule.version <= history.last.version

          raise HealingPolicyError,
                "rule #{rule.rule_id} version must increase monotonically " \
                "(have #{history.last.version}, got #{rule.version})"
        end

        def changed_self_protected_fields(current, updates)
          updates.filter_map do |field, value|
            name = field.to_sym
            next unless HealingRule::SELF_PROTECTED_FIELD_NAMES.include?(name)
            next if current.public_send(name) == value

            name
          end
        end

        def self_protected_field_list(changed)
          changed.map(&:to_s).sort.inspect
        end

        def assert_reviewed_diff!(current, changed, approval:, reviewed_diff:)
          unless reviewed_diff.is_a?(Array) &&
                 reviewed_diff.map(&:to_sym).sort == changed.sort
            raise SelfModificationError,
                  "a change to #{self_protected_field_list(changed)} requires a reviewed " \
                  "diff naming exactly those fields"
          end
          return unless current.mutation_capable?

          unless approval.is_a?(String) && approval.start_with?("human:")
            raise SelfModificationError,
                  "a mutation-capable rule requires human approval to change " \
                  "#{self_protected_field_list(changed)} (C7/P1)"
          end
        end

        def assert_promotion_authorizes!(rule_id:, current:, mode:, promotion:)
          unless promotion.is_a?(Hash)
            raise SelfPromotionError,
                  "a lifecycle transition requires a promotion record from tamoz-evals"
          end
          unless promotion["contract_digest"] == current.contract_digest
            raise SelfPromotionError,
                  "the promotion record is not digest-bound to rule #{rule_id} " \
                  "version #{current.version}"
          end
          unless promotion["mode"].to_s == mode.to_s
            raise SelfPromotionError,
                  "the promotion record authorizes #{promotion["mode"].inspect}, " \
                  "not #{mode.inspect}"
          end
        end
      end
    end
  end
end
