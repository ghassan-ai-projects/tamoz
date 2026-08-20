# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Builds bounded prior-plan, behavior, and automatic-memory prompt context.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:UtilityFunction
    # Pure renderers retain prompt ordering and the memory boundary's sentinels.
    class SessionPlanningContext
      ACTION_PHASES = %i[action repair].freeze
      ACTION_RECORD_PHASES = %w[action repair].freeze

      # Deterministic fallback for contexts that cannot safely fit in a prompt.
      # It is deliberately not a model summary and therefore creates no evidence.
      class BoundedCompactor
        VERSION = 1
        MAX_CONTEXT_BYTES = 16_384
        MAX_OBSERVATION_INLINE_BYTES = 1_024
        MAX_PREVIEW_BYTES = 256
        AUTHORITATIVE_KEYS = %w[
          goal constraints authority_revision catalog_revision plan_ids effect_ids
          approval_ids decisions pending_work next_action
        ].freeze

        Result = Data.define(:context, :observations, :compacted)

        def initialize(artifact_store: nil, tenant: nil)
          @artifact_store = artifact_store
          @tenant = tenant || artifact_store&.tenant
        end

        def compact(context:, observations: [], authoritative: {})
          compacted_observations = observations.map { |observation| compact_observation(observation) }
          return Result.new(context:, observations: compacted_observations, compacted: false) if
            fits?(context) && compacted_observations == observations

          bounded = {
            'compaction' => {
              'version' => VERSION,
              'mode' => 'deterministic',
              'context_bytes' => bytesize(context),
              'observation_count' => observations.length
            },
            'authoritative' => bounded_authoritative(authoritative),
            'observations' => compacted_observations
          }
          Result.new(
            context: fit_bounded_context(bounded),
            observations: compacted_observations,
            compacted: true
          )
        end

        private

        def compact_observation(observation)
          return observation unless observation.is_a?(Hash)

          output = observation['output']
          return observation unless output.is_a?(String) && output.bytesize > MAX_OBSERVATION_INLINE_BYTES

          digest = "sha256:#{Digest::SHA256.hexdigest(output)}"
          reference = {
            'tenant' => @tenant,
            'digest' => digest,
            'byte_count' => output.bytesize,
            'provenance' => observation['provenance'],
            'truncated' => observation['truncated'] == true
          }.compact
          @artifact_store&.retain(digest:, bytes: output, media_type: 'text/plain')
          observation.merge(
            'output' => output.byteslice(0, MAX_PREVIEW_BYTES).scrub,
            'output_reference' => reference,
            'output_truncated' => true
          )
        end

        def bounded_authoritative(authoritative)
          AUTHORITATIVE_KEYS.each_with_object({}) do |key, result|
            result[key] = authoritative.fetch(key) if authoritative.key?(key)
          end
        end

        def fit_bounded_context(context)
          return context if fits?(context)

          compacted = context.fetch('compaction')
          authoritative = context.fetch('authoritative')
          observations = context.fetch('observations')
          candidate = {
            'compaction' => compacted.merge('observations_bounded' => true),
            'authoritative' => authoritative,
            'observations' => observations.map { |observation| observation_metadata(observation) }
          }
          return candidate if fits?(candidate)

          candidate.merge(
            'authoritative' => bounded_authoritative(authoritative),
            'observations' => []
          )
        end

        def observation_metadata(observation)
          return {} unless observation.is_a?(Hash)

          observation.reject { |key, _value| key.to_s == 'output' }
        end

        def fits?(value)
          bytesize(value) <= MAX_CONTEXT_BYTES
        end

        def bytesize(value)
          Tamoz::Core.jcs(value).bytesize
        end
      end

      def self.turn_payload(thread_id:, request_id:, text:, fragments:)
        Tamoz::Core::TurnContext.task(thread_id:, request_id:, text:, fragments:)
      end

      # Builds the same durable input shape used by CommsStore for a CLI
      # follow-up. Prior request payloads are the source of truth; no live
      # conversation object is consulted.
      def self.follow_up_payload(checkpointer, thread_id:, request_id:, text:)
        fragments = prior_turn_fragments(checkpointer, thread_id:)
        turn_payload(thread_id:, request_id:, text:, fragments:)
      end

      # The transcript a channel turn carries in its request payload (nested
      # under the task Hash — the shape CommsStore#admit_and_enqueue writes).
      # A checkpointer without a request inbox answers [].
      # :reek:TooManyStatements :reek:ManualDispatch -- one durable row's
      #   payload decoding; every step is a nil-tolerant read.
      def self.transcript_from(checkpointer, thread_id:, request_id:)
        return [] unless checkpointer.respond_to?(:fetch_request)

        request = checkpointer.fetch_request(thread_id:, request_id:, namespace: [])
        task = request&.payload&.fetch('task', nil)
        return [] unless task.is_a?(Hash) && task.key?('context')

        Tamoz::Core::TurnContext.fragments_from(
          task.fetch('context'), thread_id:, request_id:
        )
      end

      def initialize(configuration:, memory:, transcript_reader: nil, artifact_store: nil, tenant: nil)
        @configuration = configuration
        @memory = memory
        @transcript_reader = transcript_reader
        @compactor = BoundedCompactor.new(artifact_store:, tenant:)
      end

      def planning_context_for(state, phase, conversation: [], observations: [])
        prompt_context = action_context(state, phase)
        add_conversation_context(prompt_context, conversation)
        add_behavior_snapshot(prompt_context, state)
        add_memory_context(prompt_context, state, phase)
        @compactor.compact(
          context: prompt_context,
          observations:,
          authoritative: authoritative_context(state, phase)
        ).context
      end

      # The transcript the channel gateway snapshotted into this turn's
      # request payload at admission, read back through the durable inbox so
      # a re-executed node sees the same input. CLI and ephemeral turns have
      # no reader and no transcript.
      def conversation_transcript(context)
        return [] unless @transcript_reader && context

        @transcript_reader.call(thread_id: context.thread_id, request_id: context.request_id)
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

      # rubocop:disable Metrics/AbcSize -- this is the single allowlisted durable envelope
      def authoritative_context(state, phase)
        session = state[:session].is_a?(Hash) ? state.fetch(:session) : {}
        route = state[:route].is_a?(Hash) ? state.fetch(:route) : {}
        {
          'goal' => state[:task],
          'constraints' => {
            'phase' => phase.to_s,
            'tool_catalog_digest' => session['tool_catalog_digest'],
            'profile_authority' => session['profile_authority']
          }.compact,
          'authority_revision' => route['authority_revision'] || session['profile_digest'],
          'catalog_revision' => route['catalog_revision'],
          'plan_ids' => state.fetch(:plan_versions, []).filter_map { |record| record['plan_id'] },
          'effect_ids' => state.fetch(:effect_intents, []).filter_map { |record| record['effect_key'] },
          'approval_ids' => state.fetch(:approvals, []).filter_map { |record| record['approval_id'] },
          'decisions' => state.fetch(:plan_reviews, []).filter_map do |record|
            record.slice('review_id', 'decision', 'plan_id')
          end,
          'pending_work' => state[:blocked],
          'next_action' => state[:next_node]
        }.compact
      end
      # rubocop:enable Metrics/AbcSize

      def self.prior_turn_fragments(checkpointer, thread_id:)
        return [] unless checkpointer.respond_to?(:request_history)

        fragments = []
        checkpointer.request_history(thread_id:, namespace: []).each do |request|
          next unless request.operation.to_sym == :turn

          task = request.payload.fetch('task', nil)
          text, context = task_parts(task)
          next if text.nil? || text.empty?

          if context
            fragments = Tamoz::Core::TurnContext.fragments_from(
              context, thread_id:, request_id: request.request_id
            )
          end
          fragments << { 'role' => 'user', 'text' => text }
        end
        fragments
      end

      def self.task_parts(task)
        return [nil, nil] if task.is_a?(Hash) && task['cancel'] == true
        return [task, nil] if task.is_a?(String)
        return [nil, nil] unless task.is_a?(Hash)

        [task['text'], task['context']]
      end
      private_class_method :prior_turn_fragments, :task_parts

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
      # before it. Channel turns carry it in the request payload; CLI turns
      # have none. It is not graph state: a new channel would change the
      # definition digest and orphan every durable checkpoint written
      # before it existed.
      def add_conversation_context(context, conversation)
        return if conversation.empty?

        context['conversation'] = {
          'note' => 'Recent messages in this conversation, oldest first. The task is ' \
                    'the latest user message; use the earlier ones to interpret it.',
          'messages' => conversation
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
