# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Admits normalized inbound updates and records their durable outcomes.
      module Admission
        # Resolves one normalized update to its durable disposition (design
        # §5): request, control reply, ignored, rejected, or callback decision.
        def admit(envelope, now:)
          decision = admission_decision(envelope)
          route_admission(envelope, decision, now:)
        end

        private

        def admission_decision(envelope)
          Comms::Admission.decide(
            envelope, surface: @descriptor,
                      binding: latest_binding(envelope),
                      conversation: conversation_for(envelope),
                      bot_username: bot_username
          )
        end

        def conversation_for(envelope)
          @store.conversation(
            surface_id:, conversation_id: envelope.fetch('conversation_id')
          )
        end

        def route_admission(envelope, decision, now:)
          case decision.disposition
          when :request
            reference = clarification_reply_reference(envelope)
            if reference
              admit_answer(envelope, reference, envelope.fetch('text'), now:)
            else
              admit_request(envelope, now:)
            end
          when :decision
            acknowledge_callback(envelope, resolve_callback(envelope, now:))
          when :rejected
            record_disposition(envelope, disposition: 'rejected', reason: decision.reason.to_s, now:)
            append_control(decision.control_reply, envelope, now:) if decision.control_reply
          when :control
            admit_control(envelope, decision, now:)
          else
            ignore_update(envelope, decision, now:)
          end
        end

        def ignore_update(envelope, decision, now:)
          record_disposition(envelope, disposition: 'ignored', reason: decision.reason.to_s, now:)
          handle_pairing_contact(envelope, now:) if decision.reason == :pairing_pending
          append_control(decision.control_reply, envelope, now:) if decision.control_reply
        end

        def admit_request(envelope, now:)
          conversation = @store.conversation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          thread = admission_thread(envelope, conversation)
          thread = fresh_thread_for_new_authority(envelope, conversation, now:) if stale_authority?(thread)
          bind_admission(envelope, thread, conversation, now:)
          history = @store.conversation_history(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), thread_id: thread
          )
          outcome = @store.admit_and_enqueue(
            envelope, surface_id:, bot_id:, thread:, profile_id: @descriptor.profile_id,
                      reservation: reservation_slots, now:, history:
          )
          return if %i[enqueued duplicate].include?(outcome)

          refuse_admission(envelope, outcome, now:)
        end

        # One typed admission refusal: durable disposition plus one bounded reply.
        def refuse_admission(envelope, outcome, now:)
          disposition, reply = ADMISSION_REFUSALS.fetch(outcome)
          record_disposition(envelope, disposition:, reason: outcome.to_s, now:)
          append_control(reply, envelope, now:)
        end

        def admit_control(envelope, decision, now:)
          if control_inbound_too_large?(envelope)
            refuse_admission(envelope, :inbound_too_large, now:)
          elsif decision.command_intent&.name == 'answer'
            handle_command(envelope, decision, now:)
          else
            outcome = record_disposition(envelope, disposition: 'ignored', reason: decision.reason.to_s, now:)
            return if outcome == :duplicate

            if decision.command_intent
              handle_command(envelope, decision, now:)
            elsif decision.control_reply
              append_control(decision.control_reply, envelope, now:)
            end
          end
        end

        def record_disposition(envelope, disposition:, reason:, now:)
          @store.disposition_only(envelope, surface_id:, bot_id:, disposition:, reason:, now:)
        end

        def control_inbound_too_large?(envelope)
          text = envelope.fetch('text')
          return false unless text

          text.bytesize > deployed_max_inbound_bytes
        end

        def deployed_max_inbound_bytes
          @store.surface(surface_id:).fetch('limits').fetch('max_inbound_bytes')
        end

        # A bound conversation admits onto the thread its durable generation derives.
        def admission_thread(envelope, conversation)
          conversation_id = envelope.fetch('conversation_id')
          return Comms::Admission.thread_id(surface_id, conversation_id) unless conversation

          Comms::Admission.thread_id(
            surface_id, conversation_id,
            generation: @store.conversation_generation(surface_id:, conversation_id:)
          )
        end
      end
    end
  end
end
