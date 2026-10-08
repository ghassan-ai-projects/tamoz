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
        return unless verification && recordable?(state.fetch(:terminal_reason), verification)

        @configuration.memory_access.record_experience(
          session: state.fetch(:session).fetch('session_id'), task: state.fetch(:task),
          plan_digest: plan_digest(state), statement: episode_statement(state, verification),
          outcome: state.fetch(:terminal_reason)
        )
      rescue StandardError
        nil
      end

      COMPLETED = %w[completed completed_without_check check_passed done verified_no_changes reported].freeze
      # A chat turn that finished without a verified outcome still happened; like every episode, it is self-reported.
      FINISHED = %w[answered done_unverified researched].freeze
      EPISODE_BYTES = 1_536
      TASK_BYTES = 300

      private

      def recordable?(reason, verification)
        FINISHED.include?(reason) || (COMPLETED.include?(reason) && verification.fetch('satisfied') == true)
      end

      # What happened, from the turn's own records: never the answer prose.
      def episode_statement(state, verification)
        parts = ["Task: #{clip(state.fetch(:task), TASK_BYTES)}",
                 ["Outcome: #{state.fetch(:terminal_reason)}", Array(verification['evidence']).first].compact.join(' - ')]
        parts += turn_parts(state) + plan_parts(state.dig(:work_plan, 'document') || {})
        clip(parts.join(' | '), EPISODE_BYTES)
      end

      def turn_parts(state)
        changes = Array(state[:work_changes]).uniq
        checks = Array(state[:work_checks]).to_h { |check| [check.fetch('name'), check.fetch('passed')] }
        parts = []
        parts << "Files changed: #{changes.join(', ')}" if changes.any?
        parts << "Checks: #{checks.map { |name, passed| "#{name} #{passed ? 'passed' : 'failed'}" }.join(', ')}" if
          checks.any?
        parts
      end

      def plan_parts(plan)
        parts = plan['goal'] ? ["Plan goal: #{plan['goal']}"] : []
        { 'decisions' => 'Decisions', 'ruled_out' => 'Ruled out' }.each do |field, label|
          parts << "#{label}: #{plan[field].join('; ')}" if Array(plan[field]).any?
        end
        parts
      end

      def plan_digest(state)
        state.dig(:work_plan, 'digest') || state[:accepted_plan]&.fetch('plan_digest') || 'sha256:none'
      end

      def clip(text, bytes) = Tamoz::Core.scrub_secrets(text.to_s.gsub(/\s+/, ' ').strip).byteslice(0, bytes).scrub('')
    end
  end
end
