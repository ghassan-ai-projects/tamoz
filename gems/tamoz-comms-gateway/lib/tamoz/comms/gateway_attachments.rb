# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Downloads an admitted attachment into the artifact store, so the worker reads bytes and never the channel.
      module Attachments
        MAX_ATTACHMENT_BYTES = 20_000_000
        MAX_IMAGE_BYTES = 5_000_000
        MAX_AUDIO_BYTES = 10_000_000
        MAX_VOICE_SECONDS = 600
        LIMITS = { 'image' => MAX_IMAGE_BYTES, 'voice' => MAX_AUDIO_BYTES, 'audio' => MAX_AUDIO_BYTES }.freeze
        LABELS = { 'document' => 'file', 'image' => 'image', 'voice' => 'voice message', 'audio' => 'audio' }.freeze
        PASS_LEVEL_ERRORS = [Comms::AuthenticationError, Comms::ThrottledError, Comms::PollerConflictError].freeze

        private

        def admit_attachment(envelope, now:)
          attachment = envelope.fetch('attachment')
          labelled = envelope.merge('text' => attachment_task(attachment, envelope['text']))
          return admit_request(labelled, now:) if @store.inbound_observed?(envelope, bot_id:)

          refusal = attachment_refusal(attachment)
          return refuse_admission(envelope, refusal, now:) if refusal

          stored = fetched(envelope, attachment, now:)
          admit_request(labelled, now:, attachment: stored) if stored
        end

        # One file that cannot be fetched or stored is refused on its own update and never stalls the poll.
        def fetched(envelope, attachment, now:)
          stored = stored_attachment(attachment)
          return stored unless stored.fetch('size_bytes').zero?

          refuse_admission(envelope, :attachment_empty, now:)
          nil
        rescue *PASS_LEVEL_ERRORS
          raise
        rescue Comms::ResponseTooLargeError
          refuse_admission(envelope, too_large(attachment), now:)
          nil
        rescue StandardError => e
          warn "tamoz: could not fetch the attachment of update #{envelope['update_id']}: #{e.class}: #{e.message}"
          refuse_admission(envelope, :attachment_unavailable, now:)
          nil
        end

        def attachment_refusal(attachment)
          size = attachment['size_bytes']
          return :attachment_empty if size&.zero?
          return too_large(attachment) if size.to_i > attachment_limit(attachment.fetch('kind'))

          :voice_too_long if attachment['duration_s'].to_i > MAX_VOICE_SECONDS
        end

        def attachment_limit(kind) = LIMITS.fetch(kind, MAX_ATTACHMENT_BYTES)

        def too_large(attachment)
          { 'image' => :image_too_large, 'voice' => :audio_too_large,
            'audio' => :audio_too_large }.fetch(attachment.fetch('kind'), :attachment_too_large)
        end

        def stored_attachment(attachment)
          assert_poller_held
          bytes = @transport.fetch_attachment(attachment.fetch('file_id'),
                                              max_bytes: attachment_limit(attachment.fetch('kind')))
          assert_poller_held
          return attachment.slice('kind').merge('size_bytes' => 0) if bytes.empty?

          digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
          attachment_store.retain(digest:, bytes:, media_type: attachment['media_type'] || 'application/octet-stream')
          attachment.slice('kind', 'media_type', 'name', 'duration_s').merge('digest' => digest,
                                                                             'size_bytes' => bytes.bytesize)
        end

        def assert_poller_held
          raise Comms::PollerConflictError, 'the poller lease ran out during a download' unless
            renew_poller(Time.now.utc)
        end

        # The worker's session reads its profile's tenant; chat_attachment_test fails if the two drift apart.
        def attachment_store = @adapter.bind_artifact_store(tenant: "profile:#{@descriptor.profile_id}")

        # The file name stays out of the task, which counts as words the user typed.
        def attachment_task(attachment, caption)
          label = attachment.fetch('media_type') == 'application/pdf' ? 'PDF' : LABELS.fetch(attachment.fetch('kind'))
          ["[#{label}]", caption].compact.join(' ')
        end
      end
    end
  end
end
