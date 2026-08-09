# frozen_string_literal: true

module Tamoz
  module Graph
    # Builds the first checkpoint for a writer-backed graph run.
    # :reek:FeatureEnvy :reek:ControlParameter :reek:LongParameterList
    # :reek:DataClump :reek:MissingSafeMethod :reek:UtilityFunction -- this
    # builder mirrors the checkpoint protocol and has no meaningful predicate twin.
    # :reek:TooManyStatements -- the checkpoint attributes are the durable start
    # protocol and stay visible together.
    # rubocop:disable Metrics/ParameterLists
    class InitialCheckpointBuilder
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def build(
        input,
        thread:,
        namespace:,
        execution_id:,
        new_execution:,
        writer:,
        prepared_state:,
        prepared_frontier:,
        durable_request_id:
      )
        latest = writer.latest
        reject_existing_thread!(latest, new_execution)
        compiled.append_checkpoint(**attributes(
          input,
          thread,
          namespace,
          execution_id,
          latest,
          writer,
          prepared_state,
          prepared_frontier,
          durable_request_id
        ))
      end

      private

      attr_reader :compiled

      def reject_existing_thread!(latest, new_execution)
        return unless latest && !new_execution

        raise StaleRequestError,
              'thread already exists; use resume, retry_failed, or new_execution: true'
      end

      def attributes(input, thread, namespace, execution_id, latest, writer, prepared_state, prepared_frontier,
                     durable_request_id)
        {
          writer:,
          thread:,
          namespace:,
          expected_base_id: latest&.id,
          mode: latest ? :turn : :start,
          execution_id:,
          state: prepared_state || compiled.state_manager.initial(input || {},
                                                                  remaining_steps: compiled.limits.max_steps),
          status: :running,
          logical_step: 0,
          frontier: prepared_frontier || compiled.route_planner.initial_frontier,
          pending: {},
          interrupts: [],
          resume_values: {},
          attempts: {},
          failure: nil,
          total_tasks: 0,
          request_transition: request_transition(writer, durable_request_id, execution_id:)
        }
      end

      def request_transition(writer, durable_request_id, execution_id:)
        return unless durable_request_id

        writer.request_transition(
          request_id: durable_request_id,
          execution_id:,
          action: :running,
          graph_status: :running
        )
      end
    end
    # rubocop:enable Metrics/ParameterLists
  end
end
