# frozen_string_literal: true

module Tamoz
  module Graph
    # Centralizes compatibility, context, writer, and execution-boundary helpers.
    # :reek:FeatureEnvy :reek:DataClump :reek:LongParameterList
    # :reek:ControlParameter :reek:DuplicateMethodCall :reek:NilCheck
    # :reek:ManualDispatch :reek:MissingSafeMethod :reek:TooManyStatements
    # :reek:UtilityFunction -- these helpers are the
    # graph execution boundary and intentionally share one adapter contract.
    # rubocop:disable Metrics/ParameterLists
    class ExecutionSupport
      DEFAULT_WRITER_TTL = 30.0

      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def compatible_latest!(thread, namespace: [], writer: nil)
        checkpoint = if writer
                       writer.latest
                     else
                       compiled.checkpointer.latest(thread_id: thread, namespace:)
                     end
        raise CheckpointConflictError, 'thread does not exist' unless checkpoint

        compatible!(checkpoint)
        checkpoint
      end

      def compatible!(checkpoint)
        return checkpoint if checkpoint.graph_name == compiled.name &&
                             checkpoint.graph_version == compiled.version &&
                             checkpoint.definition_digest == compiled.definition_digest

        raise CheckpointVersionError, 'checkpoint graph identity is incompatible'
      end

      def stale_status_reason(checkpoint, required, reason)
        checkpoint&.status == required ? nil : reason
      end

      def stale_resume_reason(checkpoint, request)
        compiled.__send__(:resume_answers).stale_reason(checkpoint, request)
      end

      def merge_resume_values(checkpoint, answers)
        compiled.__send__(:resume_answers).merge(checkpoint, answers)
      end

      def build_context(base, thread:, request_id:, execution_id:, cancellation:, emitter:)
        return base.with(execution_id:, request_id:, thread_id: thread, cancellation:, emitter:) if base

        Context.new(
          run_id: SecureRandom.uuid,
          execution_id:,
          request_id:,
          thread_id: thread,
          cancellation:,
          emitter:
        )
      end

      def bind_writer_context(context, writer)
        return context unless writer.respond_to?(:effects)
        if context.effects &&
           (!writer.respond_to?(:accepts_effects?) || !writer.accepts_effects?(context.effects))
          raise ConfigurationError, 'durable execution rejects an unbound effect journal'
        end
        if context.store &&
           (!writer.respond_to?(:accepts_store?) || !writer.accepts_store?(context.store))
          raise ConfigurationError, 'durable execution rejects an unbound Store'
        end

        context.with(effects: writer.effects, store: writer.store)
      end

      def open_writer(thread, namespace, owner_id: SecureRandom.uuid, ttl: nil, &)
        resolved_ttl = ttl || if compiled.checkpointer.respond_to?(:writer_ttl)
                                compiled.checkpointer.writer_ttl
                              else
                                DEFAULT_WRITER_TTL
                              end
        compiled.checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: resolved_ttl,
          &
        )
      end

      def ensure_ephemeral_public!
        return unless compiled.checkpointer.durable?

        raise ConfigurationError,
              'durable graph mutations require Tamoz::Graph::DurableRunner'
      end

      def stream_error_data(error)
        # The ORIGINAL error class (a NodeError wraps the node's real error):
        # the wire's typed category must reflect why the episode actually
        # failed (budget, timeout, protocol), not the generic wrapper.
        effective = if error.respond_to?(:original) && error.original
                      error.original
                    else
                      error
                    end
        {
          'graph' => compiled.name,
          'error_class' => effective.class.name.to_s,
          'category' => effective.respond_to?(:category) ? effective.category : 'internal',
          'safe_message' => effective.respond_to?(:safe_message) ? effective.safe_message : 'The graph stream failed.'
        }.freeze
      end

      def validate_concurrency!(value)
        return if %i[inline threads].include?(value) || %w[inline threads].include?(value)

        raise ConfigurationError, 'concurrency must be inline or threads'
      end

      private

      attr_reader :compiled
    end
    # rubocop:enable Metrics/ParameterLists
  end
end
