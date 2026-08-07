# frozen_string_literal: true

require "digest"
require "json"

require_relative "remediation/outcome"

module Tamoz
  module Agent
    module Healing
      # P12 §4 (P12-H2) — the bounded remediation protocol.
      #
      #   1. classify
      #   2. plan (original invariant, minimal change, effect class, authorization,
      #      verification, compensation, stop conditions)
      #   3. semantic critic review
      #   4. preflight (design §5 checklist)
      #   5. execute ONE permitted form (design §6)
      #   6. verify with the rule-supplied oracle (invariant 33)
      #   7. compensate or escalate (design §9/§10)
      #
      # Design §2's state machine is the control flow, and every transition is
      # appended to `Outcome#transitions` with the fields §2 requires: failure and
      # rule versions, plan/review digests, trace and effect ids, attempt, actor,
      # fence, timestamp, evidence, and budgets.
      #
      # Structural guarantees, each with a named test:
      #
      # * `perform` is invoked ONLY from the `:remediating` transition. Abstention,
      #   a never-mutate class, a rejected review, a preflight rejection, and an
      #   open circuit all return before it — so "no blind retry" is a property of
      #   the control flow, not of a caller's discipline.
      # * `recovered` is reachable ONLY through `Oracle.verify(...).passed`. No
      #   model text, exit code, or tool-success observation is an input to that
      #   branch (invariant 33).
      # * every phase runs inside `Healing::Scope.in_band`, so a remediation step
      #   that tries to amend its own rule, write a lifecycle mode, or reset its
      #   circuit is refused (invariant 34).
      module Remediation
        ACTOR = "tamoz.agent.healing"

        # Design §2 states, in order. `uncertain`/`reconcile` are the timeout /
        # ambiguous-effect branch.
        STATES = %i[
          observed classified planned reviewed preflighted remediating uncertain
          reconciling verifying compensating recovered escalated circuit_open
          unresolved
        ].freeze
        TERMINAL_STATES = %i[recovered escalated circuit_open unresolved].freeze

        module_function

        # The protocol's inputs are the design's inputs; collapsing them into an
        # options hash would hide the contract this method exists to enforce.
        def run(
          record:,
          rule:,
          toolbox:,
          critic:,
          original_invariant:,
          minimal_change:,
          stop_conditions:,
          context: nil,
          call_index: 0,
          attempt: 1,
          preflight_context: {},
          perform: nil,
          reconcile: nil,
          circuit: nil,
          escalation_sink: nil,
          compensation: nil,
          original_trace_id: nil,
          original_effect_id: nil,
          actor: ACTOR,
          clock: nil
        )
          unless record.is_a?(FailureRecord)
            raise HealingContractError, "remediation requires a FailureRecord"
          end
          unless rule.is_a?(HealingRule)
            raise HealingContractError, "remediation requires a HealingRule"
          end

          circuit ||= Seams::MemoryCircuitStore.new(scope: "rule:#{rule.rule_id}")
          escalation_sink ||= Seams::NullEscalationSink.new
          compensation ||= Seams::ContainOnlyCompensation.new
          ticks = 0
          clock ||= -> { ticks += 1 }

          session = Session.new(
            record:, rule:, toolbox:, critic:, original_invariant:, minimal_change:,
            stop_conditions:, context:, call_index:, attempt:, preflight_context:,
            perform:, reconcile:, circuit:, escalation_sink:, compensation:,
            original_trace_id: original_trace_id || record.execution_id || "trace.unknown",
            original_effect_id: original_effect_id || record.operation,
            actor:, clock:
          )
          Scope.in_band { session.call }
        end

        # One remediation attempt. Instantiated per `run`, never reused, so the
        # transition log cannot be shared between attempts.
        class Session
          def initialize(**arguments)
            arguments.each { |name, value| instance_variable_set(:"@#{name}", value) }
            @transitions = []
            @performed = false
          end

          def call
            transition(:observed, evidence: {"failure_digest" => @record.digest})

            # Design §10: an open circuit disables mutation and permits only safe
            # observation, reconciliation, and notification. It is checked BEFORE
            # classification so no remediation path can run at all.
            if @circuit.open?
              failure = CircuitOpen.new(
                "circuit #{@circuit.scope} is open; mutation is disabled",
                scope: @circuit.scope, evidence: @circuit.conditions
              )
              return terminate(:circuit_open, failure:)
            end

            classification = Classification.classify(@record, rule: @rule)
            transition(:classified, evidence: classification.to_h)

            if classification.route == :escalated
              failure = classification.abstention
              return terminate(:escalated, classification:, failure:)
            end

            plan = build_plan(classification)
            @plan_digest = digest_of(plan, "plan")
            transition(:planned, evidence: {"plan_digest" => @plan_digest})

            review = review_plan(plan)
            @review_digest = digest_of(review, "review")
            transition(:reviewed, evidence: review.merge("review_digest" => @review_digest))
            unless review.fetch("decision") == "accept"
              # Design §2: "plan + review -- rejected/needs authority --> escalated".
              # PreflightRejection is the typed value that names WHY without prose
              # parsing; the semantic critic's issues ride along as evidence.
              failure = PreflightRejection.new(
                "the semantic critic did not accept the remediation plan",
                precondition: :semantic_critic_review,
                detail: review.fetch("issues").first
              )
              return terminate(:escalated, classification:, plan:, review:, failure:)
            end

            rejection = run_preflight(classification)
            if rejection
              transition(
                :preflighted,
                evidence: {"passed" => false, "precondition" => rejection.precondition.to_s}
              )
              return terminate(
                :escalated, classification:, plan:, review:,
                preflight_rejection: rejection, failure: rejection
              )
            end
            transition(:preflighted, evidence: {"passed" => true})

            identity = effect_identity(classification)

            unless classification.mutating?
              # `reconcile` and `contain_escalate` never call `perform`. The §7
              # reconciliation obligation runs here, then the attempt escalates
              # honestly rather than pretending to have repaired anything.
              return non_mutating_terminal(classification, plan, review, identity)
            end

            effect_outcome = execute(identity)
            transition(
              :remediating,
              evidence: {
                "effect_key" => effect_outcome.effect_key,
                "status" => effect_outcome.status.to_s,
                "attempt_number" => effect_outcome.attempt_number,
                "reused" => effect_outcome.reused
              }
            )

            case effect_outcome.status
            when :unknown, :wait
              # Design §2: "remediating -- timeout/ambiguous effect --> uncertain
              # --> reconcile --> unresolved --> escalated". Never a retry.
              transition(:uncertain, evidence: {"status" => effect_outcome.status.to_s})
              return terminate(
                :unresolved, classification:, plan:, review:, effect_identity: identity,
                effect_outcome:,
                failure: VerificationFailure.new(
                  "the remediation effect state is unknown; reconcile before any retry",
                  reason: "effect_unknown"
                )
              )
            when :failed
              transition(:uncertain, evidence: {"status" => "failed"})
            end

            verification = verify
            transition(:verifying, evidence: verification.to_h)

            if verification.passed
              @circuit.record_success
              return terminate(
                :recovered, classification:, plan:, review:,
                effect_identity: identity, effect_outcome:, verification:
              )
            end

            # Design §8/§9: verification failure compensates, then escalates. It
            # can NEVER become `recovered`, whatever the remediation narrated.
            @circuit.record_failure(
              kind: :verification_failed,
              context: {"rule" => @rule.rule_id, "reason" => verification.reason}
            )
            compensate(
              classification:, plan:, review:, identity:, effect_outcome:, verification:
            )
          end

          private

          def non_mutating_terminal(classification, plan, review, identity)
            reconciliation = nil
            if classification.action_family == :reconcile
              transition(:reconciling, evidence: {"reconciler" => !@reconcile.nil?})
              unless @reconcile
                raise HealingContractError,
                      "an effect_unknown classification requires a reconciler (design §7)"
              end

              disposition, evidence, = @reconcile.call
              reconciliation = {"disposition" => disposition.to_s, "evidence" => evidence}
              transition(:reconciling, evidence: reconciliation)
            end

            failure = VerificationFailure.new(
              "the classified condition is not automatically remediable by this rule",
              reason: classification.reason
            )
            terminate(
              :escalated, classification:, plan:, review:, effect_identity: identity,
              failure:, extra_escalation: {"reconciliation" => reconciliation}
            )
          end

          # Invariants 25–27. The plan is BUILT deterministically from the typed
          # failure and the immutable rule; the caller supplies only the prose the
          # design requires it to name. A missing element is a contract error, not
          # a silently defaulted plan.
          def build_plan(classification)
            %i[original_invariant minimal_change stop_conditions].each do |name|
              value = instance_variable_get(:"@#{name}")
              if value.nil? || (value.respond_to?(:empty?) && value.empty?)
                raise HealingContractError,
                      "a remediation plan must name #{name} (invariant 25)"
              end
            end
            unless @rule.plan_review_policy.fetch("plan_required") == true
              raise HealingContractError, "rule #{@rule.rule_id} does not require a plan"
            end

            Tamoz::Core.deep_freeze(
              {
                "original_invariant" => @original_invariant,
                "minimal_change" => @minimal_change,
                "effect_class" => @rule.effect_class.to_s,
                "authorization" => {
                  "rule_id" => @rule.rule_id,
                  "rule_version" => @rule.version,
                  "rule_digest" => @rule.digest,
                  "authorized_scopes" => @rule.authorized_scopes,
                  "authorized_resources" => @rule.authorized_resources,
                  "original_operation_authorized" =>
                    @record.trusted_context["original_operation_authorized"] == true
                },
                "verification" => @rule.verification_oracle,
                "compensation" => @rule.compensation,
                "stop_conditions" => Array(@stop_conditions),
                "form" => classification.action_family.to_s,
                "failure_fingerprint" => @record.fingerprint,
                "budgets" => @rule.budgets
              }
            )
          end

          def review_plan(plan)
            unless @rule.plan_review_policy.fetch("semantic_critic_required") == true
              raise HealingContractError,
                    "rule #{@rule.rule_id} does not require a semantic critic review " \
                    "(invariant 26)"
            end
            unless @critic.respond_to?(:call)
              raise HealingContractError, "a semantic critic review is required"
            end

            review = @critic.call(plan)
            unless review.is_a?(Hash) && review.key?("decision") && review.key?("issues")
              raise HealingContractError,
                    "the semantic critic must return decision and issues"
            end
            unless %w[accept revise needs_input].include?(String(review.fetch("decision")))
              raise HealingContractError,
                    "the semantic critic decision must be accept, revise, or needs_input"
            end
            if review.fetch("decision") != "accept" && Array(review.fetch("issues")).empty?
              raise HealingContractError,
                    "a non-accepting semantic critic review must name issues"
            end

            Tamoz::Core.deep_freeze(
              {
                "decision" => String(review.fetch("decision")),
                "issues" => Array(review.fetch("issues")).map(&:to_s),
                "rationale" => String(review["rationale"].to_s)
              }
            )
          end

          def run_preflight(classification)
            context = Preflight::Context.new(
              **{
                record: @record, rule: @rule, classification:, attempt: @attempt,
                requested_form: classification.action_family
              }.merge(@preflight_context)
            )
            Preflight.run(context)
          end

          def effect_identity(classification)
            EffectIdentity.describe(
              original_trace_id: @original_trace_id,
              original_effect_id: @original_effect_id,
              rule_id: @rule.rule_id,
              rule_version: @rule.version,
              remediation_step: classification.action_family.to_s
            )
          end

          # Executes ONE permitted §6 form through the EXISTING effect journal. The
          # `operation` is the §7 stable key, the `safety` comes from the immutable
          # rule step, and the reconciler is required for a reconcilable step —
          # exactly the EffectDispatcher contract, no second effect model.
          def execute(identity)
            unless @perform.respond_to?(:call)
              raise HealingContractError, "a mutating remediation requires an executor"
            end
            unless @context
              raise HealingContractError,
                    "a mutating remediation requires a graph Context bound to an " \
                    "effect journal (design §7)"
            end

            step = @rule.remediation_steps.first
            @performed = true
            EffectDispatcher.run(
              context: @context,
              operation: identity.fetch("operation"),
              safety: step.fetch("safety").to_sym,
              call_index: @call_index,
              request: {
                "rule_id" => @rule.rule_id,
                "rule_version" => @rule.version,
                "form" => step.fetch("form"),
                "failure_fingerprint" => @record.fingerprint
              },
              actor: @actor,
              reconcile: @reconcile
            ) { @perform.call }
          end

          # Invariant 33. The ONLY producer of a `recovered` outcome.
          def verify = Oracle.verify(rule: @rule, toolbox: @toolbox)

          def compensate(classification:, plan:, review:, identity:, effect_outcome:, verification:)
            transition(:compensating, evidence: {"kind" => @rule.compensation.fetch("kind")})
            receipt = @compensation.compensate(
              rule: @rule, record: @record, classification:, effect_identity: identity
            )
            unless receipt.is_a?(Hash) && receipt.key?("status")
              raise HealingContractError, "a compensation must return a status"
            end

            if receipt.fetch("status") == "failed"
              # Design §9: "Failure to compensate opens the circuit."
              @circuit.record_failure(
                kind: :compensation_failed,
                context: {"rule" => @rule.rule_id}
              )
              failure = CompensationFailure.new(
                "compensation failed; the circuit is open", receipt:
              )
              return terminate(
                :circuit_open, classification:, plan:, review:,
                effect_identity: identity, effect_outcome:, verification:,
                compensation: receipt, failure:
              )
            end

            failure = VerificationFailure.new(
              "verification did not pass; the attempt is escalated, not recovered",
              oracle: @rule.verification_oracle.fetch("check_name"),
              receipt_outcome: verification.outcome, reason: verification.reason
            )
            terminate(
              :escalated, classification:, plan:, review:, effect_identity: identity,
              effect_outcome:, verification:, compensation: receipt, failure:
            )
          end

          # Terminates the attempt. Every non-recovered terminal writes an
          # escalation payload to the sink; the sink shape is the design §10 issue
          # contract (see `Seams::NullEscalationSink`).
          def terminate(
            state, classification: nil, plan: nil, review: nil, preflight_rejection: nil,
            effect_identity: nil, effect_outcome: nil, verification: nil,
            compensation: nil, failure: nil, extra_escalation: {}
          )
            unless STATES.include?(state)
              raise HealingContractError, "unknown remediation state #{state.inspect}"
            end
            if state == :recovered && !(verification && verification.passed)
              # Belt and braces for invariant 33: even a programming mistake inside
              # this file cannot produce a recovered outcome without an oracle pass.
              raise HealingPolicyError,
                    "recovered requires a recorded oracle pass (invariant 33)"
            end
            if failure && Healing.propagates?(failure)
              raise failure
            end

            transition(state, evidence: {"failure" => failure&.class&.name})

            escalation_id = nil
            unless state == :recovered
              escalation_id = @escalation_sink.record(
                escalation_payload(
                  state:, classification:, verification:, compensation:,
                  preflight_rejection:, effect_identity:, failure:
                ).merge(extra_escalation.compact)
              )
            end

            Outcome.new(
              state:, classification:, failure:, plan:, plan_digest: @plan_digest,
              review:, review_digest: @review_digest, preflight_rejection:,
              effect_identity:, effect_outcome:, verification:, compensation:,
              escalation_id:, transitions: @transitions.freeze, attempt: @attempt,
              performed: @performed
            )
          end

          def escalation_payload(
            state:, classification:, verification:, compensation:, preflight_rejection:,
            effect_identity:, failure:
          )
            {
              "failure_fingerprint" => @record.fingerprint,
              "failure_digest" => @record.digest,
              "failure_category" => @record.category.to_s,
              "never_mutate_class" => @record.never_mutate_class&.to_s,
              "rule_id" => @rule.rule_id,
              "rule_version" => @rule.version,
              "rule_digest" => @rule.digest,
              "lifecycle_mode" => @rule.lifecycle_mode.to_s,
              "attempts" => @attempt,
              "terminal_state" => state.to_s,
              "classification" => classification&.to_h,
              "plan_digest" => @plan_digest,
              "review_digest" => @review_digest,
              "preflight_precondition" => preflight_rejection&.precondition&.to_s,
              "verification" => verification&.to_h,
              "compensation" => compensation,
              "containment" => @rule.compensation,
              "effect_identity" => effect_identity,
              "before_digest" => @record.expected_digest,
              "after_digest" => @record.observed_digest,
              "failure_type" => failure&.class&.name,
              "transitions" => @transitions.dup,
              "recommended_next_action" => @rule.escalation_contract["recommended_next_action"]
            }
          end

          # Design §2: "Every transition records failure/rule versions, plan/review
          # digests, trace and effect ids, attempt, actor, fence, timestamps,
          # evidence, and budgets."
          def transition(state, evidence:)
            @transitions << {
              "state" => state.to_s,
              "failure_format_version" => @record.format_version,
              "failure_fingerprint" => @record.fingerprint,
              "rule_id" => @rule.rule_id,
              "rule_version" => @rule.version,
              "plan_digest" => @plan_digest,
              "review_digest" => @review_digest,
              "trace_id" => @original_trace_id,
              "effect_id" => @original_effect_id,
              "attempt" => @attempt,
              "actor" => @actor,
              "fence" => @context.respond_to?(:execution_id) ? @context.execution_id : nil,
              "at" => @clock.call,
              "evidence" => evidence,
              "budgets" => @rule.budgets
            }.freeze
          end

          def digest_of(value, label)
            "sha256:#{Digest::SHA256.hexdigest(
              "tamoz.agent.healing.#{label}.v1\n#{JSON.generate(Tamoz::Core.canonical(value))}"
            )}"
          end
        end
      end
    end
  end
end
