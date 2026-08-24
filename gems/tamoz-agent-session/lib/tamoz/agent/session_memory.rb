# frozen_string_literal: true

module Tamoz
  module Agent
    # Owns memory snapshots, behavior-transition claims, and episode admission.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:RepeatedConditional :reek:UtilityFunction
    # Repeated reads preserve claim/finalize and snapshot refusal order at the boundary.
    class SessionMemory
      def initialize(configuration:)
        @configuration = configuration
      end

      def memory_binding
        return {} unless @configuration.memory

        {
          memory_epoch: {
            'layers' => %w[experience knowledge wisdom],
            'retrieval_policy' => 'explicit_plus_automatic',
            'catalog_digest' => @configuration.toolbox.prompt_surface_digest
          }
        }
      end

      def claim_behavior_transition(context)
        return nil unless @configuration.memory

        pending = @configuration.memory.transitions.pending_transition
        return nil unless pending

        @configuration.memory.transitions.claim(
          transition_id: pending.transition_id,
          owner: "intake:#{context.thread_id}",
          attempt: 1
        )
      rescue Tamoz::Agent::Memory::BehaviorTransitionClaimConflictError
        nil
      end

      def claimed_behavior_channel(claimed)
        return {} unless claimed

        { behavior_transition_claim: [claimed.transition_id] }
      end

      def behavior_binding(claimed)
        return {} unless claimed

        snapshot = @configuration.memory.transitions.snapshot_for(claimed.behavior_snapshot_digest)
        {
          epoch_reason: claimed.transition_id,
          behavior_snapshot_digest: claimed.behavior_snapshot_digest,
          behavior_snapshot: snapshot,
          prompt_surface_digest: Tamoz::Agent::Memory::BehaviorTransition.extended_prompt_surface_digest(
            toolbox: @configuration.toolbox,
            behavior_snapshot_digest: claimed.behavior_snapshot_digest
          )
        }
      end

      def behavior_version(claimed)
        return claimed.behavior_version_after if claimed

        if @configuration.memory &&
           @configuration.memory.transitions.active.fetch('active_version') !=
           SessionNodes::BEHAVIOR_VERSION
          @configuration.memory.transitions.active.fetch('active_version')
        else
          SessionNodes::BEHAVIOR_VERSION
        end
      end

      def finalize_behavior_claim(state)
        return unless @configuration.memory

        Array(state.fetch(:behavior_transition_claim, [])).each do |transition_id|
          session_id = state[:session]&.fetch('session_id')
          @configuration.memory.transitions.finalize(transition_id:, consumed_by: session_id.to_s)
        rescue Tamoz::Agent::Memory::BehaviorTransitionClaimConflictError
          nil
        end
      end

      def record_episode_memory(state, verification)
        return unless completed?(state)
        return unless verification && verification.fetch('satisfied') == true

        @configuration.memory.admission.admit_episode(
          episode: episode_record(state, verification),
          owner: memory_owner
        )
      rescue StandardError
        nil
      end

      def memory_owner
        @configuration.memory_owner || 'session'
      end

      private

      def completed?(state)
        %w[completed completed_without_check check_passed].include?(state.fetch(:terminal_reason))
      end

      def episode_record(state, verification)
        session = state.fetch(:session)
        {
          session_id: session.fetch('session_id'),
          task: state.fetch(:task),
          plan_digest: state[:accepted_plan] ? state.fetch(:accepted_plan).fetch('plan_digest') : 'sha256:none',
          completed_at: Time.now.to_i,
          scopes: episode_scopes(session),
          sensitivity: :internal,
          decisions: state.fetch(:plan_versions, []).last(3).map { |record| record.fetch('plan_id') },
          corrections: [],
          observed_outcome: {
            'outcome' => verification.fetch('answer'),
            'confidence' => 0.9
          }
        }
      end

      def episode_scopes(session)
        {
          'tenant' => @configuration.memory.tenant,
          'user' => memory_owner,
          'project' => 'session',
          'session' => session.fetch('session_id')
        }
      end
    end
  end
end
