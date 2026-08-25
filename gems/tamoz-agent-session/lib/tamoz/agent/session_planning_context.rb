# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    # Builds bounded prior-plan, behavior, and automatic-memory prompt context.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:UtilityFunction
    # Pure renderers retain prompt ordering and the memory boundary's sentinels.
    # rubocop:disable Metrics/ClassLength -- the planning context owns the
    # bounded frame and its durable compaction envelope as one protocol.
    class SessionPlanningContext
      ACTION_PHASES = %i[action repair].freeze
      ACTION_RECORD_PHASES = %w[action repair].freeze

      # Deterministic fallback for contexts that cannot safely fit in a prompt.
      # It is deliberately not a model summary and therefore creates no evidence.
      class BoundedCompactor
        VERSION = 1
        MAX_CONTEXT_BYTES = 16_384
        MAX_OBSERVATIONS_BYTES = 8_192
        MAX_OBSERVATION_INLINE_BYTES = 1_024
        MAX_PREVIEW_BYTES = 256
        MAX_SUMMARY_BYTES = 4_096
        MAX_AUTHORITATIVE_BYTES = 4_096
        AUTHORITATIVE_KEYS = %w[
          goal constraints authority_revision catalog_revision plan_ids effect_ids
          approval_ids decisions pending_work next_action
        ].freeze

        Result = Data.define(:context, :observations, :compacted, :record)

        COMPACTION_SYSTEM = <<~TEXT
          You are Tamoz's context compaction stage. Return exactly one JSON object
          with a single "summary" string. Summarize only the supplied bounded
          context for the next planner. Do not add authority, capabilities,
          approvals, evidence, receipts, or claims not present in the input.
          The summary is not evidence and must not replace any observation or
          durable identifier.
        TEXT

        def initialize(artifact_store: nil, tenant: nil)
          @artifact_store = artifact_store
          store_tenant = artifact_store&.tenant
          if store_tenant && tenant && String(store_tenant) != String(tenant)
            raise ConfigurationError, 'compaction artifact tenant does not match the store tenant'
          end

          @tenant = store_tenant || tenant
        end

        def compact(context:, observations: [], authoritative: {})
          compacted_observations = bound_observations(
            observations.map { |observation| compact_observation(observation) }
          )
          return Result.new(context:, observations: compacted_observations, compacted: false, record: nil) if
            fits?(context) && compacted_observations == observations

          Result.new(
            context: fit_bounded_context(compaction_frame(context, authoritative, compacted_observations)),
            observations: compacted_observations,
            compacted: true,
            record: nil
          )
        end

        def summarize(result, effects:, durable_context:, phase:, iteration:)
          return result unless result.compacted

          input = { 'context' => result.context, 'observations' => result.observations }
          input_digest = SessionRecords.digest(input)
          call = effects.model_call(
            durable_context,
            stage: :context_compact,
            system: COMPACTION_SYSTEM,
            prompt: JSON.pretty_generate(input),
            call_index: 0,
            iteration:,
            sub_operation: 100
          )
          return summarize_with_model(result, call, phase:, input_digest:) if call.status == :succeeded

          fallback_result(result, call, phase:, input_digest:)
        end

        private

        def parse_summary(raw)
          document = JSON.parse(String(raw))
          unless document.is_a?(Hash) && document.keys == ['summary'] && document['summary'].is_a?(String)
            raise ProtocolError, 'context compaction response must contain only summary'
          end

          summary = document.fetch('summary').strip
          raise ProtocolError, 'context compaction summary must not be empty' if summary.empty?

          summary.byteslice(0, MAX_SUMMARY_BYTES).scrub
        rescue JSON::ParserError, TypeError => e
          raise ProtocolError, "invalid context compaction response: #{e.message}"
        end

        def summarize_with_model(result, call, phase:, input_digest:)
          summary = parse_summary(call.value)
          SessionRecords.reject_credential_values!({ 'summary' => summary })
          summary_result = apply_summary(result, summary)
          summary_result.with(
            record: compaction_record(
              phase:, mode: 'model', status: 'succeeded', input_digest:, summary:,
              context: summary_result.context, observations: result.observations,
              outcome: call
            )
          )
        rescue ProtocolError, SensitiveValueError
          fallback_result(result, call, phase:, input_digest:)
        end

        def fallback_result(result, call, phase:, input_digest:)
          summary = 'Deterministic bounded context retained; model summary unavailable.'
          result.with(
            record: compaction_record(
              phase:, mode: 'deterministic', status: 'fallback', input_digest:, summary:,
              context: result.context, observations: result.observations, outcome: call,
              fallback_reason: call.status.to_s
            )
          )
        end

        def compaction_frame(context, authoritative, observations)
          {
            'compaction' => {
              'version' => VERSION,
              'mode' => 'deterministic',
              'context_bytes' => bytesize(context),
              'observation_count' => observations.length
            },
            'authoritative' => bounded_authoritative(authoritative),
            'observations' => observations
          }
        end

        def apply_summary(result, summary)
          summary_digest = SessionRecords.digest('summary' => summary)
          context = {
            'compaction' => result.context.fetch('compaction').merge('mode' => 'model'),
            'authoritative' => result.context.fetch('authoritative'),
            'summary' => { 'digest' => summary_digest, 'text' => summary }
          }
          result.with(context: fit_summary_context(context))
        end

        def fit_summary_context(context)
          return context if fits?(context)

          context.merge(
            'summary' => context.fetch('summary').merge(
              'text' => context.fetch('summary').fetch('text').byteslice(0, MAX_PREVIEW_BYTES).scrub,
              'truncated' => true
            )
          )
        end

        def compaction_record(details)
          fields = compaction_base_fields(details)
          fields[:summary] = details.fetch(:summary) if details.key?(:summary)
          fields[:summary_digest] = SessionRecords.digest('summary' => details.fetch(:summary)) if
            details.fetch(:mode) == 'model'
          fields[:fallback_reason] = details.fetch(:fallback_reason) if details.key?(:fallback_reason)
          SessionRecords.build('compaction', **fields)
        end

        # rubocop:disable Metrics/AbcSize -- one versioned durable record envelope.
        def compaction_base_fields(details)
          {
            phase: details.fetch(:phase).to_s,
            mode: details.fetch(:mode),
            status: details.fetch(:status),
            input_digest: details.fetch(:input_digest),
            frame_digest: SessionRecords.digest(
              'context' => details.fetch(:context), 'observations' => details.fetch(:observations)
            ),
            observation_count: details.fetch(:observations).length,
            context_bytes: bytesize(details.fetch(:context)),
            effect_key: details.fetch(:outcome).effect_key,
            attempt_number: details.fetch(:outcome).attempt_number,
            effect_status: details.fetch(:outcome).status.to_s,
            artifact_refs: artifact_refs(details.fetch(:observations))
          }
        end
        # rubocop:enable Metrics/AbcSize

        def bound_observations(observations)
          remaining = MAX_OBSERVATIONS_BYTES
          observations.filter_map do |observation|
            candidate = fit_observation(observation, remaining)
            next if bytesize(candidate) > remaining

            remaining -= bytesize(candidate)
            candidate
          end
        end

        def fit_observation(observation, remaining)
          return observation if bytesize(observation) <= remaining

          without_output(observation).merge(
            'output_truncated' => true,
            'output_unavailable' => true
          )
        end

        def artifact_refs(observations)
          observations.filter_map do |observation|
            reference = observation['output_reference']
            reference if reference.is_a?(Hash) && reference['tenant'].is_a?(String)
          end
        end

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
          return unavailable_observation(observation, output, digest) unless @artifact_store

          @artifact_store.retain(digest:, bytes: output, media_type: 'text/plain')
          observation.merge(
            'output' => output.byteslice(0, MAX_PREVIEW_BYTES).scrub,
            'output_reference' => reference,
            'output_truncated' => true
          )
        end

        def unavailable_observation(observation, output, digest)
          observation.merge(
            'output' => output.byteslice(0, MAX_PREVIEW_BYTES).scrub,
            'output_digest' => digest,
            'output_truncated' => true,
            'output_unavailable' => true
          )
        end

        def bounded_authoritative(authoritative)
          bounded = {}
          AUTHORITATIVE_KEYS.each do |key|
            next unless authoritative.key?(key)

            value = bounded_authoritative_value(authoritative.fetch(key))
            candidate = bounded.merge(key => value)
            bounded[key] = value if bytesize(candidate) <= MAX_AUTHORITATIVE_BYTES
          end
          bounded
        end

        def bounded_authoritative_value(value)
          return value if bytesize(value) <= MAX_AUTHORITATIVE_BYTES / 2

          marker = {
            'truncated' => true,
            'digest' => SessionRecords.digest(value)
          }
          case value
          when Array
            marker.merge('count' => value.length, 'preview' => value.first(8))
          when Hash
            marker.merge('keys' => value.keys.map(&:to_s).first(32))
          when String
            marker.merge('preview' => value.byteslice(0, MAX_PREVIEW_BYTES).scrub)
          else
            marker
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

          without_output(observation)
        end

        def without_output(observation)
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

      # The durable prior-turn conversation for one thread, oldest first.
      # Context controls (/reset, /compact) truncate what the frame shows;
      # the durable request rows stay untouched either way.
      def self.conversation_history(checkpointer, thread_id:)
        prior_turn_fragments(checkpointer, thread_id:)
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

      def planning_context_for(state, phase, conversation: [])
        compact_for(state, phase, conversation:).context
      end

      def compact_for(state, phase, conversation: [], observations: [], compaction: nil)
        prompt_context = action_context(state, phase)
        add_conversation_context(prompt_context, conversation)
        add_behavior_snapshot(prompt_context, state)
        add_memory_context(prompt_context, state, phase)
        add_control_context(prompt_context, state)
        result = @compactor.compact(
          context: prompt_context,
          observations:,
          authoritative: authoritative_context(state, phase)
        )
        return result unless result.compacted && compaction

        @compactor.summarize(
          result,
          effects: compaction.fetch(:effects),
          durable_context: compaction.fetch(:durable_context),
          phase:,
          iteration: state.fetch(:repair_attempt, state.fetch(:adaptive_iteration, 0))
        )
      end

      # The transcript the channel gateway snapshotted into this turn's
      # request payload at admission, read back through the durable inbox so
      # a re-executed node sees the same input. CLI and ephemeral turns have
      # no reader and no transcript.
      def conversation_transcript(context)
        return [] unless @transcript_reader && context

        @transcript_reader.call(thread_id: context.thread_id, request_id: context.request_id)
      end

      def authoritative_frame(state)
        authoritative_context(state, :read_only)
      end

      private

      def memory_caller
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

      # rubocop:disable Metrics/AbcSize -- this is the single allowlisted durable envelope
      # rubocop:disable Metrics/MethodLength -- this is the single allowlisted durable envelope.
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
          'graph_version' => session['graph_version'],
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
      # rubocop:enable Metrics/MethodLength
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

      # Per-generation context controls (/think, /verbose, /compact) enter
      # the frame as bounded directives and pinned summaries — never as raw
      # restored history.
      def add_control_context(context, state)
        controls = Array(state[:context_controls])
        return if controls.empty?

        directives = control_directives(controls)
        context['directives'] = directives unless directives.empty?
        add_earlier_summary(context, controls)
      end

      def control_directives(controls)
        {
          'reasoning_depth' => SessionContextControls.last_preference(controls, 'think', 'reasoning_depth'),
          'answer_verbosity' => SessionContextControls.last_preference(controls, 'verbose', 'answer_verbosity')
        }.compact
      end

      def add_earlier_summary(context, controls)
        compacted = controls.reverse.find { |record| record.fetch('control') == 'compact' }
        return unless compacted&.key?('summary_digest')

        (context['conversation'] ||= {}).merge!(
          'earlier_summary' => {
            'digest' => compacted.fetch('summary_digest'),
            'text' => compacted.fetch('summary')
          }
        )
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
          caller: memory_caller,
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
      # rubocop:enable Metrics/ClassLength
    end
  end
end
