# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Downloads an admitted attachment into the runtime's artifact store, so the worker reads bytes and never the
      # channel. One attachment that cannot be fetched or stored is refused on its own; it never stalls the pass.
      module Attachments
        READABLE_KINDS = %w[document image].freeze
        MAX_ATTACHMENT_BYTES = 20_000_000
        MAX_IMAGE_BYTES = 5_000_000
        MAX_VOICE_SECONDS = 600
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

        # Only the fetch and the store are isolated per update; an admission failure behaves as it does for text.
        def fetched(envelope, attachment, now:)
          stored_attachment(attachment)
        rescue *PASS_LEVEL_ERRORS
          raise
        rescue Comms::ResponseTooLargeError
          refuse_admission(envelope, too_large(attachment), now:)
          nil
        rescue StandardError => e
          warn "tamoz: could not fetch the attachment of update #{envelope['update_id']}: #{e.class}"
          refuse_admission(envelope, :attachment_unavailable, now:)
          nil
        end

        def attachment_refusal(attachment)
          kind = attachment.fetch('kind')
          return :attachment_unreadable unless readable_kinds.include?(kind)
          return too_large(attachment) if attachment['size_bytes'].to_i > attachment_limit(kind)

          :voice_too_long if attachment['duration_s'].to_i > MAX_VOICE_SECONDS
        end

        def readable_kinds = READABLE_KINDS

        def attachment_limit(kind) = kind == 'image' ? MAX_IMAGE_BYTES : MAX_ATTACHMENT_BYTES

        def too_large(attachment) = attachment.fetch('kind') == 'image' ? :image_too_large : :attachment_too_large

        # The lease is renewed on both sides of a download, so a slow file never outlives it.
        def stored_attachment(attachment)
          held!
          bytes = @transport.fetch_attachment(attachment.fetch('file_id'),
                                              max_bytes: attachment_limit(attachment.fetch('kind')))
          held!

          digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
          attachment_store.retain(digest:, bytes:, media_type: attachment['media_type'] || 'application/octet-stream')
          attachment.slice('kind', 'media_type', 'name', 'duration_s').merge('digest' => digest,
                                                                             'size_bytes' => bytes.bytesize)
        end

        def held!
          raise Comms::PollerConflictError, 'the poller lease ran out during a download' unless
            renew_poller(Time.now.utc)
        end

        # The worker's session reads the same tenant: one artifact store per profile.
        def attachment_store = @adapter.bind_artifact_store(tenant: "profile:#{@descriptor.profile_id}")

        # What the conversation history shows for this message: what was sent, then the caption. The file name stays
        # out of the task, which counts as words the user typed.
        def attachment_task(attachment, caption)
          label = attachment.fetch('media_type') == 'application/pdf' ? 'PDF' : LABELS.fetch(attachment.fetch('kind'))
          ["[#{label}]", caption].compact.join(' ')
        end
      end
    end
  end
end
