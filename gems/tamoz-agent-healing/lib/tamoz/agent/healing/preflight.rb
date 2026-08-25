# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # SELF_HEALING_DESIGN §5 — the preflight checklist, one check per design
      # bullet plus the three OpenClaw negative cases the design makes permanent.
      #
      # Every check has a STABLE id. A rejection carries that id, so the escalation
      # record names the failed precondition without any caller parsing prose
      # (invariant 32: "an exact reviewed plan, current preconditions").
      #
      # `Preflight.run` returns `nil` on success or a `PreflightRejection` VALUE on
      # the FIRST failure in declaration order (deterministic, so the rejection
      # matrix is stable across runs and locales).
      module Preflight
        # Design §5, in design order.
        DESIGN_CHECKS = %i[
          original_operation_authorized
          rule_target_environment_behavior_match
          condition_still_present
          intended_outcome_still_valid
          effect_state_known_or_reconciling
          resources_and_locks_canonical
          within_attempt_scope_magnitude_cost_time
          compensation_or_containment_defined
        ].freeze

        # Design §5, the three OpenClaw audit findings, verbatim in intent:
        # "A missing path on read does not imply permission to create a file.
        #  A directory listing is not equivalent to requested file content.
        #  A stale patch does not authorize whole-file replacement."
        NEGATIVE_CASE_CHECKS = %i[
          missing_path_is_not_create_permission
          directory_listing_is_not_file_content
          stale_patch_is_not_whole_file_replacement
        ].freeze

        CHECK_IDS = (DESIGN_CHECKS + NEGATIVE_CASE_CHECKS).freeze

        # The context the checks read. Every field is TYPED framework evidence;
        # none of it is provider prose.
        Context = Data.define(
          :record,             # FailureRecord
          :rule,               # HealingRule
          :classification,     # Classification::Classification
          :attempt,            # 1-based attempt number for this rule/fingerprint
          :observed_condition, # true when a fresh observation still shows the fault
          :refreshed_outcome_valid,
          :current_behavior_version,
          :current_policy_version,
          :environment_id,
          :rule_environment_id,
          :canonical_resource, # the realpath-resolved resource, or nil
          :lock_state,         # :held | :not_required | :contended
          :elapsed_seconds,
          :estimated_cost,
          :estimated_magnitude,
          :reconciliation_selected,
          :requested_form,     # the §6 form about to run
          :requested_write,    # nil | {kind: :create|:replace_whole_file|:patch, path:, ...}
          :read_evidence       # {"missing_path" => [...], "listed_directories" => [...],
                               #  "read_files" => {path => digest}}
        ) do
          def initialize(
            record:, rule:, classification:, attempt: 1, observed_condition: true,
            refreshed_outcome_valid: true, current_behavior_version: nil,
            current_policy_version: nil, environment_id: "test", rule_environment_id: "test",
            canonical_resource: nil, lock_state: :not_required, elapsed_seconds: 0.0,
            estimated_cost: 0.0, estimated_magnitude: 0.0, reconciliation_selected: false,
            requested_form: nil, requested_write: nil, read_evidence: {}
          )
            super(
              record:, rule:, classification:, attempt:, observed_condition:,
              refreshed_outcome_valid:,
              current_behavior_version: current_behavior_version || record.behavior_version,
              current_policy_version: current_policy_version || record.policy_version,
              environment_id:, rule_environment_id:, canonical_resource:, lock_state:,
              elapsed_seconds:, estimated_cost:, estimated_magnitude:,
              reconciliation_selected:, requested_form:,
              requested_write: requested_write && Tamoz::Core.deep_freeze(requested_write),
              read_evidence: Tamoz::Core.deep_freeze(read_evidence)
            )
          end
        end

        # id -> predicate, ordered exactly as CHECK_IDS; DETAILS holds each
        # failure's wording.
        CHECKS = {
          # "the original operation was authorized"
          original_operation_authorized: lambda { |context|
            context.record.trusted_context["original_operation_authorized"] == true
          },
          # "the rule, target, environment, and current behavior version match"
          rule_target_environment_behavior_match: lambda { |context|
            context.environment_id == context.rule_environment_id &&
              context.current_behavior_version == context.record.behavior_version &&
              context.current_policy_version == context.record.policy_version &&
              context.rule.scope_authorized?(context.record.target_resource)
          },
          # "current state still exhibits the classified condition"
          condition_still_present: ->(context) { context.observed_condition == true },
          # "the intended outcome remains valid after refreshing state"
          intended_outcome_still_valid: ->(context) { context.refreshed_outcome_valid == true },
          # "external effect state is known or reconciliation is selected"
          # This is the NO-BLIND-RETRY gate (design §7, invariant 32/33).
          effect_state_known_or_reconciling: lambda { |context|
            !context.record.effect_unknown? || context.reconciliation_selected == true
          },
          # "resources and locks are resolved canonically"
          resources_and_locks_canonical: lambda { |context|
            next false if context.lock_state == :contended
            next true if context.record.target_resource.nil?

            !context.canonical_resource.nil?
          },
          # "the remediation stays within attempts, scope, magnitude, cost, and time"
          within_attempt_scope_magnitude_cost_time: lambda { |context|
            budgets = context.rule.budgets
            context.attempt <= budgets.fetch("max_attempts") &&
              context.estimated_magnitude <= budgets.fetch("max_magnitude") &&
              context.estimated_cost <= budgets.fetch("max_cost") &&
              context.elapsed_seconds <= budgets.fetch("max_seconds")
          },
          # "compensation or honest containment is defined"
          compensation_or_containment_defined: lambda { |context|
            !context.rule.compensation.nil? && context.rule.compensation.key?("kind")
          },
          # --- design §5 permanent negative cases -------------------------------
          missing_path_is_not_create_permission: lambda { |context|
            write = context.requested_write
            next true if write.nil?
            next true unless String(write["kind"]) == "create"

            # Creation is authorized ONLY by the rule naming the exact resource AND
            # its remediation step declaring `creates: true`. Note what is absent
            # from this predicate: `read_evidence["missing_path"]`. A 404 on read
            # contributes NOTHING to the decision — that is the whole finding.
            step = context.rule.step_for(context.requested_form)
            context.rule.authorized_resources.include?(String(write["path"])) &&
              !step.nil? && step["creates"] == true
          },
          directory_listing_is_not_file_content: lambda { |context|
            write = context.requested_write
            next true if write.nil?
            next true if String(write["kind"]) == "create"

            # Transforming existing content requires the CONTENT. Listing the
            # containing directory is evidence that a name exists, nothing more,
            # so `read_evidence["listed_directories"]` cannot satisfy this check.
            (context.read_evidence["read_files"] || {}).key?(String(write["path"]))
          },
          stale_patch_is_not_whole_file_replacement: lambda { |context|
            write = context.requested_write
            next true if write.nil?
            next true unless String(write["kind"]) == "replace_whole_file"

            # A stale-precondition failure authorizes re-reading and recomputing ONE
            # minimal conditional patch (design §13), never a whole-file replacement.
            context.classification.category != :stale_precondition
          }
        }.freeze

        DETAILS = {
          original_operation_authorized:
            "the original operation was not recorded as authorized",
          rule_target_environment_behavior_match:
            "rule, target, environment, policy, or behavior version does not match the failure",
          condition_still_present:
            "the classified condition is no longer present in current state",
          intended_outcome_still_valid:
            "the intended outcome is no longer valid after refreshing state",
          effect_state_known_or_reconciling:
            "the external effect state is unknown and no reconciliation was selected",
          resources_and_locks_canonical:
            "resources or locks are not canonically resolved",
          within_attempt_scope_magnitude_cost_time:
            "the remediation exceeds an attempt, magnitude, cost, or time budget",
          compensation_or_containment_defined:
            "no compensation or honest containment is defined",
          missing_path_is_not_create_permission:
            "a missing path on read does not imply permission to create a file",
          directory_listing_is_not_file_content:
            "a directory listing is not equivalent to the requested file content",
          stale_patch_is_not_whole_file_replacement:
            "a stale patch does not authorize whole-file replacement"
        }.freeze

        module_function

        # Returns nil (pass) or a `PreflightRejection` value naming the FIRST
        # failed check in CHECK_IDS order.
        def run(context)
          CHECK_IDS.each do |id|
            next if passes?(id, context)

            return build_rejection(id)
          end
          nil
        end

        # Every check that would fail, for the rejection matrix report. Never used
        # to decide execution — `run` short-circuits, so the decision stays
        # deterministic.
        def failures(context)
          CHECK_IDS.reject { |id| passes?(id, context) }
        end

        def passes?(id, context)
          CHECKS.fetch(id).call(context)
        end

        def build_rejection(id)
          detail = DETAILS.fetch(id)
          PreflightRejection.new(
            "preflight rejected: #{detail}", precondition: id, detail:
          )
        end
        private_class_method :passes?, :build_rejection
      end
    end
  end
end
