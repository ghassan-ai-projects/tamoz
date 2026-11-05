# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module Agent
    module SessionContextControls
      # The fenced transaction every mutating control runs through.
      module Fence
        ControlBase = Struct.new(
          :id, :execution_id, :status, :logical_step, :frontier, :pending, :interrupts,
          :resume_values, :attempts, :failure, :total_tasks, :state, keyword_init: true
        )

        private

        # The durable conversation history for `thread`, read through that thread's
        # own app checkpointer.
        def conversation_history_for(thread)
          SessionPlanningContext.conversation_history(
            app_for_thread(thread).checkpointer, thread_id: thread
          )
        end

        def control_owner(request_id)
          "tamoz.agent.session.control/#{request_id}"
        end

        def read_control_state!(thread)
          state = stored_state(thread)
          raise CheckpointConflictError, "thread #{thread} has no checkpoint" unless state

          state
        end

        # One fenced transaction: read under the lock, decide, append exactly one
        # audit record, commit. `fields` may be a lambda resolved against the
        # locked source and writer so the record carries facts measured under
        # the same fence.
        def apply_control(thread:, request_id:, control:, fields: {}, &mutate)
          guard_state!(thread)
          app = app_for_thread(thread)
          record = nil
          checkpoint = nil
          open_control_writer(app, thread, request_id) do |writer|
            source = control_base(app, writer)
            base_state = source.state.to_h
            record = SessionRecords.build('context_control', **control_header(thread, request_id, control),
                                          **resolved_fields(fields, source, writer))
            checkpoint = commit_control(writer, app, source, control_candidate(base_state, record, &mutate))
          end
          ContextControlProjection.new(
            control:, thread_id: String(thread),
            generation: generation_of(thread), checkpoint_id: checkpoint.id,
            sequence: checkpoint.sequence, record:
          )
        end

        def open_control_writer(app, thread, request_id, &)
          checkpointer = app.checkpointer
          checkpointer.open_writer(
            thread_id: thread, namespace: [],
            owner_id: control_owner(request_id), ttl: checkpointer.writer_ttl, &
          )
        end

        def control_header(thread, request_id, control)
          { control:, thread_id: String(thread), request_id: String(request_id), generation: generation_of(thread) }
        end

        def resolved_fields(fields, source, writer)
          fields.respond_to?(:call) ? fields.call(source, writer) : fields
        end

        def control_candidate(base_state, record, &mutate)
          candidate = base_state.merge(
            context_controls: Array(base_state[:context_controls]) + [record]
          )
          mutate&.call(candidate)
          candidate
        end

        # A control may run before the first turn; it then starts the thread's
        # checkpoint chain over the graph's initial channels in a terminal status
        # so real turns still apply afterwards.
        def control_base(app, writer)
          source = writer.latest
          return source if source

          ControlBase.new(
            id: nil,
            execution_id: SecureRandom.uuid,
            status: :completed,
            logical_step: 0,
            frontier: [],
            pending: {},
            interrupts: [],
            resume_values: {},
            attempts: {},
            failure: nil,
            total_tasks: 0,
            state: app.state_manager.initial({}, remaining_steps: app.limits.max_steps)
          )
        end

        def commit_control(writer, app, source, candidate)
          app.append_checkpoint(
            writer:,
            expected_base_id: source.id,
            mode: source.id ? :advance : :start,
            execution_id: source.execution_id,
            state: candidate,
            status: source.status,
            logical_step: source.logical_step,
            frontier: source.frontier,
            pending: source.pending,
            interrupts: source.interrupts,
            resume_values: source.resume_values,
            attempts: source.attempts,
            failure: source.failure,
            total_tasks: source.total_tasks
          )
        end
      end
    end
  end
end
