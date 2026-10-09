# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Talk
    # Browser update → normalized InboundEnvelope wire. The digest binds the update and the audio, never a transcript.
    class Normalizer
      PARSER_VERSION = 1
      DIGEST_DOMAIN = 'tamoz.talk.update.v1'
      CORRESPONDENT = 'talk:user:1'
      CONVERSATION = 'talk:chat:1'
      MAX_UPDATE_ID = (2**53) - 1

      def initialize(surface_id:, surface_revision:)
        @surface_id = surface_id
        @surface_revision = surface_revision
      end

      def text(update_id:, text:)
        envelope(update_id:, kind: text.start_with?('/') ? 'command' : 'text', text:, digest_fields: [text])
      end

      def decision(update_id:, action:, reference:, message_id:)
        data = "#{action}:#{reference}"
        envelope(update_id:, kind: 'callback', text: data, callback_message_id: message_id,
                 callback_query_id: update_id.to_s, digest_fields: [data, message_id])
      end

      def utterance(update_id:, audio:, duration_s:)
        digest = Digest::SHA256.hexdigest(audio)
        attachment = { 'kind' => 'voice', 'file_id' => "talk-#{update_id}", 'file_unique_id' => digest,
                       'media_type' => 'audio/wav', 'name' => nil, 'size_bytes' => audio.bytesize,
                       'duration_s' => duration_s.ceil }
        envelope(update_id:, kind: 'attachment', text: nil, attachment:, digest_fields: [digest])
      end

      def self.valid_update_id?(value) = value.is_a?(Integer) && value.positive? && value <= MAX_UPDATE_ID

      private

      def envelope(update_id:, kind:, text:, digest_fields:, **fields)
        raise Comms::ValidationError, 'update_id must be a positive integer below 2^53' unless
          self.class.valid_update_id?(update_id)

        Comms::InboundEnvelope.new(
          surface_id: @surface_id, surface_revision: @surface_revision, update_id:,
          raw_payload_hash: Digest::SHA256.hexdigest("#{DIGEST_DOMAIN}\n#{JSON.generate([update_id, kind,
                                                                                         *digest_fields])}"),
          parser_version: PARSER_VERSION, kind:, correspondent_id: CORRESPONDENT, conversation_id: CONVERSATION,
          text:, observed_time: Time.now.utc, **fields
        ).wire
      end
    end
  end
end
