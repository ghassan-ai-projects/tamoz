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

        # The binding pins the authority the deployed surface carries, so the
        # worker can refuse a bound thread whose on-disk profile no longer
        # matches (F25-SEC-01). A surface deployed without a pinned digest
        # records none, and the worker refuses that thread rather than running
        # it under unverified authority.
        def bind_thread_profile(thread)
          @adapter.store.put(
            THREAD_PROFILE_NAMESPACE, thread,
            { 'profile' => @descriptor.profile_id,
              'profile_digest' => @descriptor.profile_digest,
              'recorded_at' => Time.now.utc.iso8601(6) }.compact,
            if_version: nil
          )
        rescue StoreConflictError
          nil
        end

        # A thread stays pinned to the authority it was bound under; when the surface's profile has
        # changed since (re-running setup, editing the profile), the conversation moves to a new thread
        # bound to the current profile instead of every message failing on the stale pin.
        def stale_authority?(thread)
          entry = @adapter.store.get(THREAD_PROFILE_NAMESPACE, thread)
          return false if entry.nil? || entry.deleted

          entry.value.values_at('profile', 'profile_digest') != [@descriptor.profile_id, @descriptor.profile_digest]
        end

        def fresh_thread_for_new_authority(envelope, conversation, now:)
          @store.bump_generation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          append_control(SETTINGS_CHANGED_REPLY, envelope, now:)
          admission_thread(envelope, conversation)
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
