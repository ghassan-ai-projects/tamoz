# frozen_string_literal: true

module Tamoz
  module Agent
    # Builds bounded prior-plan, behavior, and automatic-memory prompt context.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:UtilityFunction
    # Pure renderers retain prompt ordering and the memory boundary's sentinels.
    class SessionPlanningContext
      ACTION_PHASES = %i[action repair].freeze
      ACTION_RECORD_PHASES = %w[action repair].freeze

      def initialize(configuration:, memory:)
        @configuration = configuration
        @memory = memory
      end

      def planning_context_for(state, phase)
        context = action_context(state, phase)
        add_conversation_context(context, state)
        add_behavior_snapshot(context, state)
        add_memory_context(context, state, phase)
        context
      end

      def memory_caller(_state)
        @configuration.memory.caller(
          user: memory_owner,
          project: 'session',
          sensitivity: :internal,
          compatibility: {
            'graph_version' => '1',
            'behavior_version' => @memory.behavior_version(nil)
          }
        )
      end

      def memory_owner
        @configuration.memory_owner || 'session'
      end

      private

      def action_context(state, phase)
        return {} unless ACTION_PHASES.include?(phase)

        {
          'prior_action_plans' => prior_plans(state),
          'prior_action_reviews' => prior_reviews(state),
          'prior_action_signatures' => state.fetch(:seen_action_signatures).sort,
          'prior_failure_signatures' => state.fetch(:seen_failure_signatures).sort
        }
      end

      def prior_plans(state)
        state.fetch(:plan_versions).filter_map do |record|
          record.fetch('plan') if ACTION_RECORD_PHASES.include?(record.fetch('phase'))
        end
      end

      def prior_reviews(state)
        state.fetch(:plan_reviews).filter_map do |record|
          next unless record.fetch('layer') == 'semantic'

          {
            'decision' => record.fetch('decision'),
            'issues' => record.fetch('issues'),
            'rationale' => record.fetch('rationale', '')
          }
        end
      end

      # The transcript the current task arrived with, for EVERY phase: a
      # follow-up like "yes, do that" or "make it blue instead" only reads
      # as a task when the planner and the reviewer can see what came
      # before it. Channel turns carry it in state; CLI turns have none.
      def add_conversation_context(context, state)
        messages = state.fetch(:conversation)
        return if messages.empty?

        context['conversation'] = {
          'note' => 'Recent messages in this conversation, oldest first. The task is ' \
                    'the latest user message; use the earlier ones to interpret it.',
          'messages' => messages
        }
      end

      def add_behavior_snapshot(context, state)
        snapshot = state[:session] && state[:session]['behavior_snapshot']
        return unless snapshot

        context['behavior_snapshot'] = {
          'marker' => Tamoz::Agent::Memory::BehaviorTransition::SNAPSHOT_MARKERS,
          'content' => snapshot
        }
      end

      def add_memory_context(context, state, phase)
        return unless @configuration.memory && ACTION_PHASES.include?(phase)
        return unless (state[:session] && state[:session]['memory_epoch']).is_a?(Hash)

        recall = @configuration.memory.retrieval.recall(
          caller: memory_caller(state),
          query: { terms: [state.fetch(:task)] },
          automatic: true
        )
        context['memory'] = memory_records(recall) unless recall.records.empty?
      end

      def memory_records(recall)
        recall.records.map do |record|
          {
            'memory_id' => record.memory_id,
            'record_version' => record.record_version,
            'layer' => record.layer.to_s,
            'class' => record.klass.to_s,
            'statement' => record.statement
          }
        end
      end
    end
  end
end
