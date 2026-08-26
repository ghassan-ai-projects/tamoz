# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Keeps the write-once route and profile binding beside admission, where
      # their ordering is part of the inbound authorization contract.
      module AdmissionBinding
        private

        # Authority binding precedes work: the deterministic thread and
        # surface profile are bound before the first request enqueues.
        def bind_admission(envelope, thread, conversation, now:)
          if conversation.nil?
            bind_thread_profile(thread)
            @store.bind_conversation(
              Comms::Conversation.new(
                surface_id:, surface_revision: envelope.fetch('surface_revision'),
                conversation_id: envelope.fetch('conversation_id'), thread_id: thread,
                profile_id: @descriptor.profile_id, bound_at: now
              ).wire,
              now:
            )
            bind_allowlisted_correspondent(envelope, now:)
          elsif conversation.fetch('thread_id') != thread
            bind_thread_profile(thread)
          end
        end

        def bind_thread_profile(thread)
          @adapter.store.put(
            THREAD_PROFILE_NAMESPACE, thread,
            { 'profile' => @descriptor.profile_id, 'recorded_at' => Time.now.utc.iso8601(6) },
            if_version: nil
          )
        rescue StoreConflictError
          nil
        end

        # Write-once: an operator pairing is never overwritten by allowlist data.
        def bind_allowlisted_correspondent(envelope, now:)
          @store.bind_correspondent(
            Comms::Binding.new(
              surface_id:, surface_revision: envelope.fetch('surface_revision'),
              correspondent_id: envelope.fetch('correspondent_id'),
              conversation_id: envelope.fetch('conversation_id'),
              bound_at: now, bound_by: 'gateway:allowlist'
            ).wire,
            now:
          )
        end
      end
    end
  end
end
