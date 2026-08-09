# frozen_string_literal: true

module Tamoz
  module Graph
    # Owns checkpoint-backed state reads, manual updates, persistence, and snapshots.
    # :reek:FeatureEnvy :reek:DataClump :reek:LongParameterList
    # :reek:DuplicateMethodCall :reek:NestedIterators :reek:RepeatedConditional
    # :reek:ControlParameter :reek:TooManyStatements -- these methods implement
    # the checkpoint protocol and keep its state transitions explicit.
    # :reek:MissingSafeMethod :reek:UtilityFunction -- operations are boundary
    # commands and have no useful non-raising twins.
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class StateOperations
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def state(thread:, checkpoint_id: nil, namespace: [])
        checkpoint = if checkpoint_id
                       compiled.checkpointer.find(thread_id: thread, namespace:, checkpoint_id:)
                     else
                       compiled.checkpointer.latest(thread_id: thread, namespace:)
                     end
        raise CheckpointConflictError, 'checkpoint not found' unless checkpoint

        compatible!(checkpoint)
        snapshot(checkpoint)
      end

      def history(thread:, namespace: [], limit: compiled.limits.history_limit)
        unless limit.is_a?(Integer) && limit.positive?
          raise ConfigurationError, 'history limit must be a positive integer'
        end
        if limit > compiled.limits.history_limit
          raise StateLimitError, "history limit exceeds #{compiled.limits.history_limit}"
        end

        compiled.checkpointer.history(thread_id: thread, namespace:, limit:).map do |checkpoint|
          compatible!(checkpoint)
          snapshot(checkpoint)
        end.freeze
      end

      def update(
        update,
        thread:,
        checkpoint_id: nil,
        execution_id: SecureRandom.uuid
      )
        compiled.__send__(:ensure_ephemeral_public!)
        open_writer(thread, []) do |writer|
          latest = compatible_latest(thread, writer:)
          source = checkpoint_id ? writer.find(checkpoint_id:) : latest
          raise CheckpointConflictError, 'checkpoint not found' unless source

          compatible!(source)
          candidate = updated_state(source, update)
          historical = source.id != latest.id
          frontier = source.frontier.map do |entry|
            historical ? entry.with(activation_checkpoint_id: nil) : entry
          end.freeze
          checkpoint = append_checkpoint(
            writer:,
            thread:,
            namespace: [],
            expected_base_id: source.id,
            mode: historical ? :fork : :advance,
            execution_id: historical ? execution_id : source.execution_id,
            state: candidate,
            status: frontier.empty? ? :completed : :running,
            logical_step: source.logical_step,
            frontier:,
            pending: {},
            interrupts: [],
            resume_values: {},
            attempts: historical ? {} : source.attempts,
            failure: nil,
            total_tasks: historical ? 0 : source.total_tasks
          )
          snapshot(checkpoint)
        end
      end

      def append_checkpoint(writer:, **attributes)
        state = attributes.fetch(:state)
        attributes[:execution_id] = SafeText.normalize(
          attributes.fetch(:execution_id),
          name: 'execution id',
          max_bytes: 256,
          error_class: ConfigurationError
        )
        attributes.delete(:thread)
        attributes.delete(:namespace)
        consumed_task_ids = attributes.delete(:consumed_task_ids) || []
        request_transition = attributes.delete(:request_transition)
        writer.append_checkpoint(
          expected_base_id: attributes.delete(:expected_base_id),
          mode: attributes.delete(:mode),
          attributes: {
            graph_name: compiled.name,
            graph_version: compiled.version,
            definition_digest: compiled.definition_digest,
            state_bytes: compiled.state_manager.state_bytes(state),
            **attributes
          },
          consumed_task_ids:,
          request_transition:
        )
      end

      def snapshot(checkpoint)
        Snapshot.new(
          checkpoint_id: checkpoint.id,
          parent_checkpoint_id: checkpoint.parent_id,
          sequence: checkpoint.sequence,
          thread_id: checkpoint.thread_id,
          namespace: checkpoint.namespace,
          execution_id: checkpoint.execution_id,
          status: checkpoint.status,
          logical_step: checkpoint.logical_step,
          state: checkpoint.state,
          next: checkpoint.frontier.map(&:node).uniq.freeze,
          pending_task_ids: checkpoint.pending.keys.sort.freeze,
          interrupts: checkpoint.interrupts,
          failure: checkpoint.failure,
          definition_digest: checkpoint.definition_digest
        )
      end

      private

      attr_reader :compiled

      def updated_state(source, update)
        manual = Outcome.new(
          task_id: 'manual.update',
          attempt_id: 'manual.attempt',
          base_checkpoint_id: source.id,
          node: compiled.definition.nodes.keys.first,
          path: %w[manual update],
          update: compiled.state_manager.normalize_update(update),
          goto: nil
        )
        compiled.state_manager.apply_outcomes(
          source.state,
          [manual],
          remaining_steps: [compiled.limits.max_steps - source.logical_step, 0].max
        )
      end

      def compatible_latest(thread, writer:, namespace: [])
        compiled.__send__(:compatible_latest!, thread, namespace:, writer:)
      end

      def compatible!(checkpoint)
        compiled.__send__(:compatible!, checkpoint)
      end

      def open_writer(thread, namespace, &)
        compiled.__send__(:open_writer, thread, namespace, &)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
