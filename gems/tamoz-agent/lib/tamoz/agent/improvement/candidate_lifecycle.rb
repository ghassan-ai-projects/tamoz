# frozen_string_literal: true

module Tamoz
  module Agent
    module Improvement
      # Candidate-only profile/skill/config lifecycle. The candidate is immutable
      # and powerless until a human approval binds its exact digest. State-changing
      # phases use `EffectDispatcher`; profile activation then records the existing
      # operator transition consumed at the next thread boundary.
      class CandidateLifecycle
        APPROVAL_DOMAIN = "tamoz.agent.improvement.approval.v1\n"
        ACTOR = 'tamoz.agent.improvement'
        EFFECT_CALLS = { apply: 4_100, restart_health_verify: 4_101, activate: 4_102, rollback: 4_103 }.freeze
        SAFETY = :reconcilable

        Approval = Data.define(:operation, :actor, :authority_digest, :digest, :evidence)
        Result = Data.define(:stage, :outcome) do
          def status = outcome.status
          def value = outcome.value
          def succeeded? = status == :succeeded
          def unknown? = status == :unknown
        end

        def self.propose(**attributes)
          CandidateProposal.build(**attributes)
        end

        def self.approval_digest(proposal:, candidate_digest:, operation:, actor:, authority_digest:)
          Tamoz::Core.digest(
            APPROVAL_DOMAIN,
            {
              'proposal_digest' => proposal.digest,
              'candidate_digest' => candidate_digest,
              'operation' => String(operation),
              'actor' => String(actor),
              'authority_digest' => authority_digest
            }
          )
        end

        def initialize(
          proposal:, candidate_resolver:, current_authority: nil,
          effect_runner: EffectDispatcher, actor: ACTOR
        )
          @proposal = proposal
          @candidate_resolver = candidate_resolver
          @current_authority = current_authority
          @effect_runner = effect_runner
          @actor = String(actor)
          @phase = :proposed
          @approvals = {}
        end

        attr_reader :proposal, :candidate, :phase

        def validate!
          candidate = resolve_candidate
          validate_identity!(candidate)
          CandidatePolicy.validate!(
            proposal: @proposal, candidate:, current_authority: @current_authority
          )
          @candidate = Tamoz::Core.deep_freeze(Tamoz::Core.canonical(candidate))
          @phase = :validated
          @candidate
        end

        def approval_request(operation: :apply, actor: @actor, authority_digest: @proposal.from_digest)
          require_phase!(operation.to_sym == :rollback ? :active : :validated, :approval)
          validate_actor!(actor)
          digest = self.class.approval_digest(
            proposal: @proposal, candidate_digest: @proposal.to_digest,
            operation:, actor:, authority_digest:
          )
          {
            'operation' => String(operation), 'actor' => String(actor),
            'authority_digest' => authority_digest, 'candidate_digest' => @proposal.to_digest,
            'proposal_digest' => @proposal.digest, 'approval_digest' => digest
          }.freeze
        end

        def approve!(approval_digest:, evidence:, operation: :apply, actor: @actor,
                     authority_digest: @proposal.from_digest)
          request = approval_request(operation:, actor:, authority_digest:)
          unless approval_digest == request.fetch('approval_digest')
            raise ApprovalDigestError, 'approval does not bind the exact candidate lifecycle request'
          end
          unless evidence == "human:#{actor}"
            raise UngatedActivationError, "candidate approval must be the exact human:#{actor} artifact"
          end

          @approvals[String(operation)] = Approval.new(
            operation: String(operation), actor: String(actor), authority_digest:,
            digest: approval_digest, evidence:
          ).freeze
        end

        def apply!(context:, perform:, reconcile:)
          approval = approval_for(:apply)
          run_effect(
            context:, stage: :apply, approval:, perform:, reconcile:
          )
        end

        def restart_health_verify!(context:, perform:, reconcile:)
          require_phase!(:applied, :restart_health_verify)
          approval = approval_for(:apply)
          run_effect(
            context:, stage: :restart_health_verify, approval:, perform:, reconcile:
          )
        end

        def activate!(context:, reconcile:, transition_registry: nil, adoption_registry: nil, perform: nil)
          require_phase!(:verified, :activate)
          approval = approval_for(:apply)
          perform ||= profile_activation(approval, transition_registry, adoption_registry)
          run_effect(context:, stage: :activate, approval:, perform:, reconcile:)
        end

        def rollback!(context:, reconcile:, perform: nil, transition_registry: nil)
          require_phase!(:active, :rollback)
          approval = approval_for(:rollback)
          perform ||= profile_rollback(approval, transition_registry)
          run_effect(context:, stage: :rollback, approval:, perform:, reconcile:)
        end

        private

        def resolve_candidate
          unless @candidate_resolver.respond_to?(:call)
            raise ImprovementPolicyError, 'candidate lifecycle requires an artifact resolver'
          end

          candidate = @candidate_resolver.call(@proposal.to_digest)
          raise EvaluatorTamperError, 'candidate artifact could not be resolved' unless candidate.is_a?(Hash)

          candidate
        end

        def validate_identity!(candidate)
          required = %w[profile_id digest scope]
          missing = required.reject { |key| candidate.key?(key) }
          raise ImprovementPolicyError, "candidate artifact is missing #{missing.join(', ')}" unless missing.empty?
          return if required.all? do |key|
            candidate.fetch(key).to_s == @proposal.public_send(key == 'digest' ? :to_digest : key).to_s
          end

          raise EvaluatorTamperError, 'candidate artifact does not match the proposal'
        end

        def validate_actor!(actor)
          raise ImprovementPolicyError, 'candidate approval requires an actor' if String(actor).empty?
          return unless String(actor) == @proposal.created_by

          raise SelfPromotionError, 'candidate creator cannot approve the candidate'
        end

        def approval_for(operation)
          @approvals.fetch(String(operation)) do
            raise UngatedActivationError, "candidate requires human approval for #{operation}"
          end
        end

        def require_phase!(expected, operation)
          return if @phase == expected

          raise CandidateUnknownError, "candidate lifecycle cannot #{operation} after #{@phase}"
        end

        def run_effect(context:, stage:, approval:, perform:, reconcile:)
          validate_callable!(perform, "#{stage} effect")
          validate_callable!(reconcile, "#{stage} reconciler")
          outcome = @effect_runner.run(
            context:, operation: "improvement.#{stage}", safety: SAFETY,
            call_index: EFFECT_CALLS.fetch(stage), request: effect_request(stage, approval),
            actor: ACTOR, reconcile:
          ) { perform.call }
          unless outcome.respond_to?(:status)
            raise ImprovementPolicyError, "#{stage} effect runner returned an untyped outcome"
          end

          @phase = stage_result_phase(stage, outcome.status)
          Result.new(stage:, outcome:).freeze
        end

        def effect_request(stage, approval)
          {
            'stage' => stage.to_s, 'proposal_digest' => @proposal.digest,
            'candidate_digest' => @proposal.to_digest, 'approval_digest' => approval.digest,
            'authority_digest' => approval.authority_digest
          }
        end

        def stage_result_phase(stage, status)
          return :unknown if status == :unknown
          return @phase unless status == :succeeded

          { apply: :applied, restart_health_verify: :verified, activate: :active, rollback: :rolled_back }.fetch(stage)
        end

        def validate_callable!(value, label)
          return if value.respond_to?(:call)

          raise ImprovementPolicyError, "#{label} requires a callable"
        end

        def profile_activation(approval, transition_registry, adoption_registry)
          validate_profile_registries!(transition_registry, adoption_registry)
          lambda do
            adoption_registry.activate(@proposal.profile_id, @proposal.to_digest)
            @proposal.promote!(
              registry: transition_registry, candidate_resolver: @candidate_resolver,
              actor: approval.actor, human_gate_evidence: approval.evidence
            )
          end
        end

        def profile_rollback(_approval, transition_registry)
          unless transition_registry.respond_to?(:record)
            raise ImprovementPolicyError, 'profile rollback requires the transition registry seam'
          end

          lambda do
            transition_registry.record(
              Profile::Transition.new(
                thread_id: @proposal.thread_id, profile_id: @proposal.profile_id,
                from_digest: @proposal.to_digest, to_digest: @proposal.from_digest,
                reason: "candidate_#{@proposal.scope}_rollback"
              )
            )
          end
        end

        def validate_profile_registries!(transition_registry, adoption_registry)
          return if transition_registry.respond_to?(:record) && adoption_registry.respond_to?(:activate)

          raise ImprovementPolicyError, 'profile activation requires the existing profile registries'
        end
      end
    end
  end
end
