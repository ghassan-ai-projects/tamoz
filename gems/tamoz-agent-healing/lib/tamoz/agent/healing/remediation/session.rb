# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # One attempt, never reused, so transition state cannot leak across runs.
        # :reek:DuplicateMethodCall — repeated reads make state checks explicit in order.
        # :reek:InstanceVariableAssumption — keyword capture preserves run's public contract.
        # :reek:LongParameterList — terminal fields mirror Outcome's public schema.
        # :reek:NilCheck — nil is the explicit absent-reconciler representation.
        # :reek:TooManyInstanceVariables — Session coordinates the attempt collaborators.
        # :reek:TooManyStatements — ordered protocol phases remain visible in one path.
        class Session
          def initialize(**arguments)
            arguments.each { |name, value| instance_variable_set(:"@#{name}", value) }
            @evidence = AttemptEvidence.new(
              record: @record, rule: @rule, original_trace_id: @original_trace_id,
              original_effect_id: @original_effect_id, attempt: @attempt,
              actor: @actor, context: @context, clock: @clock
            )
            @transitions = @evidence.transitions
            @performed = false
          end

          # rubocop:disable Metrics/AbcSize
          def call
            transition(:observed, evidence: { 'failure_digest' => @record.digest })

            terminal = circuit_guard
            return terminal if terminal

            classification = Classification.classify(@record, rule: @rule)
            transition(:classified, evidence: classification.to_h)
            return terminate(:escalated, classification:, failure: classification.abstention) if
              classification.route == :escalated

            plan = build_plan(classification)
            review = evaluate_review(plan, classification)
            return review if review.is_a?(Outcome)

            preflight_terminal = run_preflight_check(classification, plan, review)
            return preflight_terminal if preflight_terminal

            identity = effect_identity(classification)
            return non_mutating_terminal(classification, plan, review, identity) unless classification.mutating?

            effect_outcome = execute_effect(classification, identity)
            ambiguous_terminal = handle_ambiguous_effect(effect_outcome, classification, plan, review, identity)
            return ambiguous_terminal if ambiguous_terminal

            verify_or_compensate(effect_outcome, identity, classification, plan, review)
          end
          # rubocop:enable Metrics/AbcSize

          private

          def non_mutating_terminal(classification, plan, review, identity)
            reconciliation = nil
            if classification.action_family == :reconcile
              transition(:reconciling, evidence: { 'reconciler' => !@reconcile.nil? })
              unless @reconcile
                raise HealingContractError,
                      'an effect_unknown classification requires a reconciler (design §7)'
              end

              disposition, evidence, = @reconcile.call
              reconciliation = { 'disposition' => disposition.to_s, 'evidence' => evidence }
              transition(:reconciling, evidence: reconciliation)
            end

            failure = VerificationFailure.new(
              'the classified condition is not automatically remediable by this rule',
              reason: classification.reason
            )
            terminate(
              :escalated, classification:, plan:, review:, effect_identity: identity,
                          failure:, extra_escalation: { 'reconciliation' => reconciliation }
            )
          end

          def run_preflight(classification)
            PreflightCheck.new(
              record: @record, rule: @rule, attempt: @attempt,
              context: @preflight_context
            ).call(classification)
          end

          def circuit_guard
            return nil unless @circuit.open?

            failure = CircuitOpen.new(
              "circuit #{@circuit.scope} is open; mutation is disabled",
              scope: @circuit.scope, evidence: @circuit.conditions
            )
            terminate(:circuit_open, failure:)
          end

          def build_plan(classification)
            plan = PlanBuilder.new(
              record: @record, rule: @rule, original_invariant: @original_invariant,
              minimal_change: @minimal_change, stop_conditions: @stop_conditions
            ).call(classification)
            @plan_digest = @evidence.digest(plan, 'plan')
            transition(:planned, evidence: { 'plan_digest' => @plan_digest })
            plan
          end

          def evaluate_review(plan, classification)
            review = PlanReview.new(rule: @rule, critic: @critic).call(plan)
            @review_digest = @evidence.digest(review, 'review')
            transition(:reviewed, evidence: review.merge('review_digest' => @review_digest))
            return review if review.fetch('decision') == 'accept'

            terminate(
              :escalated, classification:, plan:, review:,
                          failure: PreflightRejection.new(
                            'the semantic critic did not accept the remediation plan',
                            precondition: :semantic_critic_review,
                            detail: review.fetch('issues').first
                          )
            )
          end

          def run_preflight_check(classification, plan, review)
            rejection = run_preflight(classification)
            if rejection
              transition(
                :preflighted,
                evidence: { 'passed' => false, 'precondition' => rejection.precondition.to_s }
              )
              return terminate(
                :escalated, classification:, plan:, review:,
                            preflight_rejection: rejection, failure: rejection
              )
            end

            transition(:preflighted, evidence: { 'passed' => true })
            nil
          end

          def effect_identity(classification)
            execution_for.identity(classification)
          end

          def execution_for
            EffectExecution.new(
              record: @record, rule: @rule, toolbox: @toolbox, context: @context,
              call_index: @call_index, perform: @perform, reconcile: @reconcile,
              original_trace_id: @original_trace_id,
              original_effect_id: @original_effect_id, actor: @actor
            )
          end

          def execute_effect(_classification, identity)
            execution_for.call(identity) { @performed = true }.tap do |outcome|
              transition(
                :remediating,
                evidence: {
                  'effect_key' => outcome.effect_key,
                  'status' => outcome.status.to_s,
                  'attempt_number' => outcome.attempt_number,
                  'reused' => outcome.reused
                }
              )
            end
          end

          def handle_ambiguous_effect(effect_outcome, classification, plan, review, identity)
            case effect_outcome.status
            when :unknown, :wait
              transition(:uncertain, evidence: { 'status' => effect_outcome.status.to_s })
              terminate(
                :unresolved,
                classification:, plan:, review:,
                effect_identity: identity, effect_outcome:,
                failure: VerificationFailure.new(
                  'the remediation effect state is unknown; reconcile before any retry',
                  reason: 'effect_unknown'
                )
              )
            when :failed
              transition(:uncertain, evidence: { 'status' => 'failed' })
            end
          end

          def verify_or_compensate(effect_outcome, identity, classification, plan, review)
            verification = execution_for.verify
            transition(:verifying, evidence: verification.to_h)

            if verification.passed
              @circuit.record_success
              return terminate(
                :recovered, classification:, plan:, review:,
                            effect_identity: identity, effect_outcome:, verification:
              )
            end

            compensate_and_terminate(effect_outcome, identity, classification, plan, review, verification)
          end

          # rubocop:disable Metrics/ParameterLists
          def compensate_and_terminate(effect_outcome, identity, classification, plan, review, verification)
            @circuit.record_failure(
              kind: :verification_failed,
              context: { 'rule' => @rule.rule_id, 'reason' => verification.reason }
            )
            transition(:compensating, evidence: { 'kind' => @rule.compensation.fetch('kind') })
            compensation = CompensationFlow.new(
              rule: @rule, record: @record, compensation: @compensation, circuit: @circuit
            ).call(classification:, effect_identity: identity, verification:)
            terminate(
              compensation.state, classification:, plan:, review:,
                                  effect_identity: identity, effect_outcome:, verification:,
                                  compensation: compensation.receipt, failure: compensation.failure
            )
          end
          # rubocop:enable Metrics/ParameterLists

          # rubocop:disable Metrics/ParameterLists
          def terminate(
            state, classification: nil, plan: nil, review: nil, preflight_rejection: nil,
            effect_identity: nil, effect_outcome: nil, verification: nil,
            compensation: nil, failure: nil, extra_escalation: {}
          )
            validate_terminal_state!(state, verification, failure)
            transition(state, evidence: { 'failure' => failure&.class&.name })
            escalation_id = record_escalation_if_needed(state, classification, effect_identity,
                                                        verification, compensation,
                                                        preflight_rejection, failure,
                                                        extra_escalation)
            assemble_outcome(
              state, classification, failure, plan, review, preflight_rejection,
              effect_identity, effect_outcome, verification, compensation, escalation_id
            )
          end

          def validate_terminal_state!(state, verification, failure)
            raise HealingContractError, "unknown remediation state #{state.inspect}" unless STATES.include?(state)
            if state == :recovered && !(verification && verification.passed)
              raise HealingPolicyError,
                    'recovered requires a recorded oracle pass (invariant 33)'
            end
            raise failure if failure && Healing.propagates?(failure)
          end

          def record_escalation_if_needed(state, classification, effect_identity,
                                          verification, compensation, preflight_rejection,
                                          failure, extra_escalation)
            return nil if state == :recovered

            terminal = {
              state:, classification:, verification:, compensation:,
              preflight_rejection:, effect_identity:, failure:
            }
            payload = EscalationPayload.new(
              record: @record, rule: @rule, attempt: @attempt,
              transitions: @transitions,
              digests: { plan: @plan_digest, review: @review_digest }
            ).call(terminal)
            @escalation_sink.record(payload.merge(extra_escalation.compact))
          end

          def assemble_outcome(state, classification, failure, plan, review, preflight_rejection,
                               effect_identity, effect_outcome, verification, compensation,
                               escalation_id)
            Outcome.new(
              state:, classification:, failure:, plan:, plan_digest: @plan_digest,
              review:, review_digest: @review_digest, preflight_rejection:,
              effect_identity:, effect_outcome:, verification:, compensation:,
              escalation_id:, transitions: @transitions.freeze, attempt: @attempt,
              performed: @performed
            )
          end
          # rubocop:enable Metrics/ParameterLists

          # Design §2: "Every transition records failure/rule versions, plan/review
          # digests, trace and effect ids, attempt, actor, fence, timestamps,
          # evidence, and budgets."
          def transition(state, evidence:)
            @evidence.record(
              state, plan_digest: @plan_digest, review_digest: @review_digest,
                     evidence:
            )
          end
        end
      end
    end
  end
end
