# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    module Healing
      # P12 §4 / SELF_HEALING_DESIGN §4 — the immutable, versioned rule contract.
      #
      # Design §4 field list, verbatim:
      #
      #   rule_id, version, owner, lifecycle mode
      #   typed trigger plus minimum confidence
      #   risk and effect class
      #   authorized scopes/resources
      #   required plan/review policy
      #   preconditions
      #   remediation steps
      #   idempotency/effect identity
      #   attempt, magnitude, cost, and time budgets
      #   verification oracle
      #   compensation/containment
      #   circuit conditions and reset authority
      #   issue/escalation contract
      #   eval suite and promotion evidence
      #
      # The record is a frozen `Data`, so no field can be written in place. The
      # invariant-34 property that actually needs proving is that a rule cannot
      # produce a NEW version of itself that widens its matcher, oracle, budgets,
      # authority, or circuit — that guard lives in `RuleRegistry#amend`, backed by
      # `Healing::Scope`, and is proven by executing an attempted self-edit.
      class HealingRule < Data.define(
        :format_version, :rule_id, :version, :owner, :lifecycle_mode,
        :trigger, :minimum_confidence, :risk_class, :effect_class,
        :authorized_scopes, :authorized_resources, :plan_review_policy,
        :preconditions, :remediation_steps, :effect_identity,
        :budgets, :verification_oracle, :compensation, :circuit_conditions,
        :reset_authority, :escalation_contract, :eval_suite, :promotion_evidence,
        :created_at_ms
      )
        FORMAT_VERSION = 1
        DIGEST_DOMAIN = "tamoz.agent.healing.rule"
        MAX_ID_BYTES = 256

        # Design §11 lifecycle, in order.
        LIFECYCLE_MODES = %i[
          draft replay shadow fault_injection canary active retired
        ].freeze
        # Design §4: "Rules default to disabled/shadow." Anything at or past
        # `fault_injection` needs a promotion record; the registry refuses to load
        # such a rule without one (the seam builder B fills).
        SELF_SERVE_MODES = %i[draft replay shadow].freeze

        RISK_CLASSES = %i[low moderate high].freeze
        # Mirrors the effect-journal safety vocabulary; no second taxonomy.
        EFFECT_CLASSES = %i[read_only idempotent transactional reconcilable unsafe].freeze

        # Invariant 34: the fields a rule may never change about itself. Grouped by
        # the design's own words so the test can assert group-by-group.
        SELF_PROTECTED_FIELDS = {
          matcher: %i[trigger minimum_confidence],
          oracle: %i[verification_oracle],
          budgets: %i[budgets],
          authority: %i[
            risk_class effect_class authorized_scopes authorized_resources
            plan_review_policy remediation_steps preconditions owner
          ],
          circuit: %i[circuit_conditions reset_authority],
          # Not in the design sentence but in invariant 34's second half
          # ("rules cannot promote or reset themselves").
          lifecycle: %i[lifecycle_mode promotion_evidence]
        }.freeze
        SELF_PROTECTED_FIELD_NAMES =
          SELF_PROTECTED_FIELDS.values.flatten.uniq.freeze

        REQUIRED_BUDGET_KEYS = %w[max_attempts max_magnitude max_cost max_seconds].freeze
        REQUIRED_PLAN_REVIEW_KEYS = %w[plan_required semantic_critic_required human_approval_required].freeze
        REQUIRED_ORACLE_KEYS = %w[kind check_name digest].freeze
        # Invariant 33 / P12 §4 (C2): the oracle IS a configured check. No other
        # kind exists in v1; a rule naming anything else is refused at construction
        # so "the model said so" can never become an oracle kind.
        ORACLE_KINDS = %w[configured_check].freeze
        COMPENSATION_KINDS = %w[
          restore_preimage cancel_with_receipt authorized_compensation contain_only
        ].freeze
        OPTIONAL_TRIGGER_MATCHERS = {
          "operations" => "operation", "tools" => "tool", "effect_states" => "effect_state"
        }.freeze

        def initialize(
          format_version: FORMAT_VERSION,
          rule_id:,
          version: 1,
          owner:,
          lifecycle_mode: :draft,
          trigger:,
          minimum_confidence: 1.0,
          risk_class: :low,
          effect_class: :idempotent,
          authorized_scopes: [],
          authorized_resources: [],
          plan_review_policy: nil,
          preconditions: [],
          remediation_steps: [],
          effect_identity: nil,
          budgets: nil,
          verification_oracle:,
          compensation: nil,
          circuit_conditions: [],
          reset_authority: nil,
          escalation_contract: nil,
          eval_suite: nil,
          promotion_evidence: nil,
          created_at_ms: 0
        )
          validate_header(format_version, version, minimum_confidence)

          super(
            format_version:,
            rule_id: validate_id(rule_id, "rule_id"),
            version:,
            owner: validate_id(owner, "owner"),
            lifecycle_mode: validate_member(lifecycle_mode, LIFECYCLE_MODES, "lifecycle_mode"),
            trigger: Tamoz::Core.deep_freeze(validate_trigger(trigger)),
            minimum_confidence: minimum_confidence.to_f,
            risk_class: validate_member(risk_class, RISK_CLASSES, "risk_class"),
            effect_class: validate_member(effect_class, EFFECT_CLASSES, "effect_class"),
            authorized_scopes: Tamoz::Core.deep_freeze(validate_strings(authorized_scopes, "authorized_scopes")),
            authorized_resources: Tamoz::Core.deep_freeze(
              validate_strings(authorized_resources, "authorized_resources")
            ),
            plan_review_policy: Tamoz::Core.deep_freeze(validate_plan_review(plan_review_policy)),
            preconditions: Tamoz::Core.deep_freeze(validate_preconditions(preconditions)),
            remediation_steps: Tamoz::Core.deep_freeze(validate_steps(remediation_steps)),
            effect_identity: Tamoz::Core.deep_freeze(validate_effect_identity(effect_identity)),
            budgets: Tamoz::Core.deep_freeze(validate_budgets(budgets)),
            verification_oracle: Tamoz::Core.deep_freeze(validate_oracle(verification_oracle)),
            compensation: Tamoz::Core.deep_freeze(validate_compensation(compensation)),
            circuit_conditions: Tamoz::Core.deep_freeze(
              validate_strings(circuit_conditions, "circuit_conditions")
            ),
            reset_authority: reset_authority.nil? ? nil : validate_id(reset_authority, "reset_authority"),
            escalation_contract: Tamoz::Core.deep_freeze(validate_escalation(escalation_contract)),
            eval_suite: eval_suite.nil? ? nil : validate_id(eval_suite, "eval_suite"),
            promotion_evidence: promotion_evidence.nil? ? nil : Tamoz::Core.deep_freeze(promotion_evidence),
            created_at_ms:
          )
        end

        # The typed trigger. Matching reads ONLY the typed signal, never prose.
        def triggers?(signal)
          categories = trigger.fetch("categories")
          return false unless categories.include?(signal.fetch("category"))

          OPTIONAL_TRIGGER_MATCHERS.all? do |trigger_key, signal_key|
            subset_admits?(trigger[trigger_key], signal[signal_key])
          end
        end

        def trigger_categories = trigger.fetch("categories").map(&:to_sym)

        # A rule may only take an action family it declared in `remediation_steps`.
        # `contain_escalate`, `reconcile`, `abstain`, and `observe` are always
        # available: narrowing is never a widening.
        def authorized_family?(family)
          return true if Classification::NON_FORM_FAMILIES.include?(family)
          return true if family == :contain_escalate

          remediation_steps.any? { |step| step.fetch("form") == family.to_s }
        end

        def step_for(family)
          remediation_steps.find { |step| step.fetch("form") == family.to_s }
        end

        def mutation_capable?
          remediation_steps.any? do |step|
            Classification::MUTATING_FAMILIES.include?(step.fetch("form").to_sym)
          end
        end

        def scope_authorized?(resource)
          return true if authorized_resources.empty?

          authorized_resources.include?(String(resource))
        end

        def budget(name) = budgets.fetch(String(name))

        def digest
          Tamoz::Core.digest("#{DIGEST_DOMAIN}.v1\n", to_h)
        end

        # The identity a promotion record must be bound to (invariant 34): the rule
        # WITHOUT its lifecycle mode and promotion evidence, so a mode change can
        # never silently reuse another rule's evidence.
        def contract_digest
          body = to_h.reject { |key, _| %w[lifecycle_mode promotion_evidence].include?(key) }
          Tamoz::Core.digest("#{DIGEST_DOMAIN}.contract.v1\n", body)
        end

        def to_h
          {
            "format_version" => format_version,
            "rule_id" => rule_id,
            "version" => version,
            "owner" => owner,
            "lifecycle_mode" => lifecycle_mode.to_s,
            "trigger" => trigger,
            "minimum_confidence" => minimum_confidence,
            "risk_class" => risk_class.to_s,
            "effect_class" => effect_class.to_s,
            "authorized_scopes" => authorized_scopes,
            "authorized_resources" => authorized_resources,
            "plan_review_policy" => plan_review_policy,
            "preconditions" => preconditions,
            "remediation_steps" => remediation_steps,
            "effect_identity" => effect_identity,
            "budgets" => budgets,
            "verification_oracle" => verification_oracle,
            "compensation" => compensation,
            "circuit_conditions" => circuit_conditions,
            "reset_authority" => reset_authority,
            "escalation_contract" => escalation_contract,
            "eval_suite" => eval_suite,
            "promotion_evidence" => promotion_evidence,
            "created_at_ms" => created_at_ms
          }
        end

        # The constructor keyword hash for this exact rule. `RuleRegistry#amend`
        # merges its updates onto this, so a new version starts from the current
        # contract rather than from defaults (a defaulted field would be a silent
        # widening).
        def to_init_hash
          {
            format_version:, rule_id:, version:, owner:, lifecycle_mode:, trigger:,
            minimum_confidence:, risk_class:, effect_class:, authorized_scopes:,
            authorized_resources:, plan_review_policy:, preconditions:,
            remediation_steps:, effect_identity:, budgets:, verification_oracle:,
            compensation:, circuit_conditions:, reset_authority:,
            escalation_contract:, eval_suite:, promotion_evidence:, created_at_ms:
          }
        end

        # Invariant 18: the version gate runs before any other field is read.
        def self.from_h(hash)
          raise CheckpointCorruptionError, "HealingRule must be an object" unless hash.is_a?(Hash)

          version = hash["format_version"]
          unless version == FORMAT_VERSION
            raise CheckpointVersionError,
                  "HealingRule format_version #{version.inspect} is not supported"
          end

          new(
            format_version: version,
            rule_id: hash.fetch("rule_id"),
            version: hash.fetch("version"),
            owner: hash.fetch("owner"),
            lifecycle_mode: hash.fetch("lifecycle_mode").to_sym,
            trigger: hash.fetch("trigger"),
            minimum_confidence: hash.fetch("minimum_confidence"),
            risk_class: hash.fetch("risk_class").to_sym,
            effect_class: hash.fetch("effect_class").to_sym,
            authorized_scopes: hash.fetch("authorized_scopes"),
            authorized_resources: hash.fetch("authorized_resources"),
            plan_review_policy: hash.fetch("plan_review_policy"),
            preconditions: hash.fetch("preconditions"),
            remediation_steps: hash.fetch("remediation_steps"),
            effect_identity: hash.fetch("effect_identity"),
            budgets: hash.fetch("budgets"),
            verification_oracle: hash.fetch("verification_oracle"),
            compensation: hash.fetch("compensation"),
            circuit_conditions: hash.fetch("circuit_conditions"),
            reset_authority: hash["reset_authority"],
            escalation_contract: hash.fetch("escalation_contract"),
            eval_suite: hash["eval_suite"],
            promotion_evidence: hash["promotion_evidence"],
            created_at_ms: hash.fetch("created_at_ms", 0)
          )
        rescue KeyError => error
          raise CheckpointCorruptionError, "HealingRule is incomplete: #{error.message}"
        end

        private

        def validate_header(format_version, version, minimum_confidence)
          validate_format_version(format_version)
          validate_rule_version(version)
          validate_minimum_confidence(minimum_confidence)
        end

        def validate_format_version(format_version)
          return if format_version == FORMAT_VERSION

          raise HealingPolicyError,
                "HealingRule format_version #{format_version.inspect} is not supported"
        end

        def validate_rule_version(version)
          return if version.is_a?(Integer) && version.positive?

          raise HealingPolicyError, "rule version must be a positive integer"
        end

        def validate_minimum_confidence(minimum_confidence)
          return if minimum_confidence.is_a?(Numeric) && minimum_confidence.between?(0.0, 1.0)

          raise HealingPolicyError, "minimum_confidence must be between 0.0 and 1.0"
        end

        def validate_id(value, name)
          SafeText.normalize(
            value, name:, max_bytes: MAX_ID_BYTES, error_class: HealingPolicyError
          )
        end

        def validate_member(value, set, name)
          unless set.include?(value)
            raise HealingPolicyError, "#{name} must be one of #{set.map(&:inspect).join(", ")}"
          end

          value
        end

        def validate_strings(value, name)
          unless value.is_a?(Array) && value.all?(String)
            raise HealingPolicyError, "#{name} must be an array of strings"
          end

          value
        end

        def subset_admits?(allowed, actual)
          return true unless allowed.is_a?(Array) && !allowed.empty?

          allowed.include?(actual)
        end

        def validate_hash(value, name)
          unless value.is_a?(Hash)
            raise HealingPolicyError, "#{name} must be an object"
          end

          value
        end

        def validate_array(value, name)
          unless value.is_a?(Array)
            raise HealingPolicyError, "#{name} must be an array"
          end

          value
        end

        def validate_trigger(value)
          validate_trigger_shape(value)
          validate_trigger_keys(value)
          validate_trigger_categories(value.fetch("categories"))
          value
        end

        def validate_trigger_shape(value)
          return if value.is_a?(Hash) && value["categories"].is_a?(Array) && !value["categories"].empty?

          raise HealingPolicyError, "trigger must carry a non-empty categories array"
        end

        def validate_trigger_keys(value)
          unknown = value.keys.map(&:to_s) - %w[categories operations tools effect_states]
          return if unknown.empty?

          raise HealingPolicyError, "trigger does not accept #{unknown.sort.inspect}"
        end

        def validate_trigger_categories(categories)
          categories.each do |name|
            category = String(name).to_sym
            unless FailureRecord::CATEGORIES.include?(category)
              raise HealingPolicyError, "trigger names unknown category #{name.inspect}"
            end
            next unless FailureRecord::NEVER_MUTATE_CATEGORIES.include?(category)

            raise HealingPolicyError,
                  "trigger names never-mutate category #{name.inspect}; the five " \
                  "never-mutate classes are escalated, never remediated"
          end
        end

        def validate_plan_review(value)
          validate_hash(value, "plan_review_policy")
          validate_plan_review_keys(value)
          validate_plan_and_critic_required(value)
          value
        end

        def validate_plan_review_keys(value)
          missing = REQUIRED_PLAN_REVIEW_KEYS - value.keys.map(&:to_s)
          return if missing.empty?

          raise HealingPolicyError,
                "plan_review_policy is missing #{missing.sort.inspect}"
        end

        def validate_plan_and_critic_required(value)
          return if value["plan_required"] == true && value["semantic_critic_required"] == true

          raise HealingPolicyError,
                "a remediation rule must require a plan and a semantic critic review " \
                "(invariants 25-26)"
        end

        def validate_preconditions(value)
          unless value.is_a?(Array) && value.all?(String)
            raise HealingPolicyError, "preconditions must be an array of check ids"
          end

          unknown = value - Preflight::CHECK_IDS.map(&:to_s)
          unless unknown.empty?
            raise HealingPolicyError,
                  "preconditions name unknown preflight checks #{unknown.sort.inspect}"
          end
          value
        end

        def validate_steps(value)
          validate_array(value, "remediation_steps")
          validate_single_step(value)
          value.each { |step| validate_remediation_step(step) }
          value
        end

        def validate_single_step(value)
          return if value.length <= 1

          raise HealingPolicyError,
                "a rule declares at most ONE remediation form (design §6)"
        end

        def validate_remediation_step(step)
          validate_step_form(step)
          validate_step_safety(step)
          validate_safety_form_pair(step)
        end

        def validate_step_form(step)
          unless step.is_a?(Hash) && step.key?("form")
            raise HealingPolicyError, "each remediation step must name a form"
          end

          form = String(step.fetch("form")).to_sym
          return if Classification::PERMITTED_FORMS.key?(form)

          raise HealingPolicyError,
                "remediation form #{form.inspect} is not one of the design §6 " \
                "permitted forms #{Classification::PERMITTED_FORMS.keys.inspect}"
        end

        def validate_step_safety(step)
          return if step.key?("safety") &&
                    FailureRecord::EFFECT_SAFETIES.include?(String(step.fetch("safety")))

          raise HealingPolicyError,
                "remediation step must declare an effect safety from " \
                "#{FailureRecord::EFFECT_SAFETIES.inspect}"
        end

        def validate_safety_form_pair(step)
          return unless String(step.fetch("safety")) == "unsafe"
          return unless String(step.fetch("form")).to_sym == :bounded_retry

          raise HealingPolicyError,
                "an unsafe effect may never declare bounded_retry (design §7)"
        end

        def validate_effect_identity(value)
          unless value.is_a?(Hash) && value["domain"].is_a?(String) && !value["domain"].empty?
            raise HealingPolicyError, "effect_identity must carry a domain"
          end

          value
        end

        def validate_budgets(value)
          validate_hash(value, "budgets")
          validate_budget_keys(value)
          validate_budget_entries(value)
          validate_attempt_budget(value)
          value
        end

        def validate_budget_keys(value)
          missing = REQUIRED_BUDGET_KEYS - value.keys.map(&:to_s)
          return if missing.empty?

          raise HealingPolicyError, "budgets are missing #{missing.sort.inspect}"
        end

        def validate_budget_entries(value)
          REQUIRED_BUDGET_KEYS.each do |key|
            entry = value.fetch(key)
            next if entry.is_a?(Numeric) && entry.finite? && entry.positive?

            raise HealingPolicyError, "budget #{key} must be a positive finite number"
          end
        end

        def validate_attempt_budget(value)
          max_attempts = value.fetch("max_attempts")
          unless max_attempts.is_a?(Integer)
            raise HealingPolicyError, "budget max_attempts must be an integer"
          end
          return unless max_attempts > EffectDispatcher::MAX_ATTEMPTS

          raise HealingPolicyError,
                "budget max_attempts may not exceed the effect journal's " \
                "MAX_ATTEMPTS (#{EffectDispatcher::MAX_ATTEMPTS})"
        end

        # Invariant 33 / C2. The oracle is a CONFIGURED CHECK, pinned by digest.
        def validate_oracle(value)
          validate_hash(value, "verification_oracle")
          validate_oracle_keys(value)
          validate_oracle_kind(value)
          validate_oracle_digest(value)
          validate_oracle_check_name(value)
          value
        end

        def validate_oracle_keys(value)
          missing = REQUIRED_ORACLE_KEYS - value.keys.map(&:to_s)
          return if missing.empty?

          raise HealingPolicyError, "verification_oracle is missing #{missing.sort.inspect}"
        end

        def validate_oracle_kind(value)
          return if ORACLE_KINDS.include?(String(value.fetch("kind")))

          raise HealingPolicyError,
                "verification_oracle kind must be one of #{ORACLE_KINDS.inspect}; " \
                "a model explanation is never an oracle (invariant 33)"
        end

        def validate_oracle_digest(value)
          digest = value.fetch("digest")
          return if digest.is_a?(String) && digest.start_with?("sha256:")

          raise HealingPolicyError, "verification_oracle digest must be a sha256: digest"
        end

        def validate_oracle_check_name(value)
          SafeText.normalize(
            value.fetch("check_name"), name: "verification_oracle check_name",
            max_bytes: MAX_ID_BYTES, error_class: HealingPolicyError
          )
        end

        def validate_compensation(value)
          unless value.is_a?(Hash) && value.key?("kind")
            raise HealingPolicyError, "compensation/containment must be defined (design §5)"
          end

          unless COMPENSATION_KINDS.include?(String(value.fetch("kind")))
            raise HealingPolicyError,
                  "compensation kind #{value.fetch("kind").inspect} is not a design §9 response"
          end
          value
        end

        def validate_escalation(value)
          unless value.is_a?(Hash) && value.key?("sink")
            raise HealingPolicyError, "escalation_contract must name a sink"
          end

          value
        end
      end
    end
  end
end
