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

          # One visible path preserves the legal mutation/verification ordering.
          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          def call
            transition(:observed, evidence: { 'failure_digest' => @record.digest })

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

            plan = PlanBuilder.new(
              record: @record, rule: @rule, original_invariant: @original_invariant,
              minimal_change: @minimal_change, stop_conditions: @stop_conditions
            ).call(classification)
            @plan_digest = @evidence.digest(plan, 'plan')
            transition(:planned, evidence: { 'plan_digest' => @plan_digest })

            review = PlanReview.new(rule: @rule, critic: @critic).call(plan)
            @review_digest = @evidence.digest(review, 'review')
            transition(:reviewed, evidence: review.merge('review_digest' => @review_digest))
            unless review.fetch('decision') == 'accept'
              # Design §2: "plan + review -- rejected/needs authority --> escalated".
              # PreflightRejection is the typed value that names WHY without prose
              # parsing; the semantic critic's issues ride along as evidence.
              failure = PreflightRejection.new(
                'the semantic critic did not accept the remediation plan',
                precondition: :semantic_critic_review,
                detail: review.fetch('issues').first
              )
              return terminate(:escalated, classification:, plan:, review:, failure:)
            end

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

            execution = EffectExecution.new(
              record: @record, rule: @rule, toolbox: @toolbox, context: @context,
              call_index: @call_index, perform: @perform, reconcile: @reconcile,
              original_trace_id: @original_trace_id,
              original_effect_id: @original_effect_id, actor: @actor
            )
            identity = execution.identity(classification)

            unless classification.mutating?
              # `reconcile` and `contain_escalate` never call `perform`. The §7
              # reconciliation obligation runs here, then the attempt escalates
              # honestly rather than pretending to have repaired anything.
              return non_mutating_terminal(classification, plan, review, identity)
            end

            effect_outcome = execution.call(identity) { @performed = true }
            transition(
              :remediating,
              evidence: {
                'effect_key' => effect_outcome.effect_key,
                'status' => effect_outcome.status.to_s,
                'attempt_number' => effect_outcome.attempt_number,
                'reused' => effect_outcome.reused
              }
            )

            case effect_outcome.status
            when :unknown, :wait
              # Design §2: "remediating -- timeout/ambiguous effect --> uncertain
              # --> reconcile --> unresolved --> escalated". Never a retry.
              transition(:uncertain, evidence: { 'status' => effect_outcome.status.to_s })
              return terminate(
                :unresolved, classification:, plan:, review:, effect_identity: identity,
                             effect_outcome:,
                             failure: VerificationFailure.new(
                               'the remediation effect state is unknown; reconcile before any retry',
                               reason: 'effect_unknown'
                             )
              )
            when :failed
              transition(:uncertain, evidence: { 'status' => 'failed' })
            end

            verification = execution.verify
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
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

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

          # Every non-recovered terminal writes the design §10 issue contract.
          # Terminal assembly carries the complete public Outcome contract. Its
          # keyword list is explicit so no terminal field can disappear in a hash.
          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          # rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity
          def terminate(
            state, classification: nil, plan: nil, review: nil, preflight_rejection: nil,
            effect_identity: nil, effect_outcome: nil, verification: nil,
            compensation: nil, failure: nil, extra_escalation: {}
          )
            raise HealingContractError, "unknown remediation state #{state.inspect}" unless STATES.include?(state)
            if state == :recovered && !(verification && verification.passed)
              # Belt and braces for invariant 33: even a programming mistake inside
              # this file cannot produce a recovered outcome without an oracle pass.
              raise HealingPolicyError,
                    'recovered requires a recorded oracle pass (invariant 33)'
            end
            raise failure if failure && Healing.propagates?(failure)

            transition(state, evidence: { 'failure' => failure&.class&.name })

            escalation_id = nil
            unless state == :recovered
              terminal = {
                state:, classification:, verification:, compensation:,
                preflight_rejection:, effect_identity:, failure:
              }
              payload = EscalationPayload.new(
                record: @record, rule: @rule, attempt: @attempt,
                transitions: @transitions,
                digests: { plan: @plan_digest, review: @review_digest }
              ).call(terminal)
              escalation_id = @escalation_sink.record(payload.merge(extra_escalation.compact))
            end

            Outcome.new(
              state:, classification:, failure:, plan:, plan_digest: @plan_digest,
              review:, review_digest: @review_digest, preflight_rejection:,
              effect_identity:, effect_outcome:, verification:, compensation:,
              escalation_id:, transitions: @transitions.freeze, attempt: @attempt,
              performed: @performed
            )
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          # rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity

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
