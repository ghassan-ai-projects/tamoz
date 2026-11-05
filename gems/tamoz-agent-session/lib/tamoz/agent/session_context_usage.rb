# frozen_string_literal: true

module Tamoz
  module Agent
    module SessionContextControls
      # /usage: the read-only projection of durable budget and accounting facts.
      module UsageReport
        UsageProjection = Data.define(:thread_id, :generation, :requests, :controls, :pinned_budgets,
                                      :observation_bytes, :lifecycle_events) do
          def document
            {
              'control' => 'usage',
              'thread_id' => thread_id,
              'generation' => generation,
              'requests' => requests,
              'controls' => controls,
              'pinned_budgets' => pinned_budgets,
              'observation_bytes' => observation_bytes,
              'lifecycle_events' => lifecycle_events
            }
          end
        end

        # /usage — read-only projection of durable budget/accounting facts.
        # Token/cost rollups are not recorded at this layer and are reported as
        # absent rather than invented.
        def usage_report(thread:)
          state = read_control_state!(thread)
          UsageProjection.new(
            thread_id: String(thread),
            generation: generation_of(thread),
            requests: request_counts(app_for_thread(thread), thread),
            controls: control_counts(state),
            pinned_budgets: state.dig(:session, 'profile_budgets') || {},
            observation_bytes: {
              'used' => observation_bytes_used(state),
              'ceiling' => SessionNodes::MAX_OBSERVATION_BYTES
            },
            lifecycle_events: Array(state[:lifecycle_events]).length
          )
        end

        private

        def request_counts(app, thread)
          checkpointer = app.checkpointer
          return {} unless checkpointer.respond_to?(:request_history)

          checkpointer.request_history(thread_id: thread, namespace: [])
                      .group_by { |request| request.operation.to_s }
                      .transform_values(&:length)
        end

        def control_counts(state)
          Array(state[:context_controls]).each_with_object(Hash.new(0)) do |record, counts|
            counts[record.fetch('control')] += 1
          end
        end

        def observation_bytes_used(state)
          Array(state[:observations]).sum do |record|
            record.fetch('output_bytes') do
              record.fetch('output', '').bytesize
            end
          end
        end
      end
    end
  end
end
