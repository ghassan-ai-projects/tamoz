# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Telegram
    # Raw Bot API update → normalized InboundEnvelope wire (design §6.2).
    # Ids are bounded numeric telegram ids; private chats normalize to
    # `telegram:chat:<id>`, group/supergroup/channel to their typed prefixes
    # (admission refuses them, design §5). Everything unsupported collapses
    # into a typed `unsupported` envelope — never raw JSON in the store.
    # The normalizer is one deterministic projection of raw update JSON;
    # the metric smells measure the projection, not a choice to overload.
    # :reek:FeatureEnvy, :reek:DuplicateMethodCall, :reek:TooManyStatements
    # :reek:UtilityFunction, :reek:DataClump, :reek:NilCheck
    class Normalizer
      PARSER_VERSION = 1
      DIGEST_DOMAIN = 'tamoz.telegram.update.v2'
      TYPES = {
        'group' => 'telegram:group:',
        'supergroup' => 'telegram:supergroup:',
        'channel' => 'telegram:channel:'
      }.freeze

      def initialize(surface_id:, surface_revision:, bot_username: nil)
        @surface_id = surface_id
        @surface_revision = surface_revision
        @bot_username = bot_username
      end

      # @param update [Hash] one raw update from getUpdates.
      # @return [Hash] the InboundEnvelope wire.
      def normalize(update)
        update_id = update.fetch('update_id')
        message = update['message']
        callback = update['callback_query']
        member = update['my_chat_member'] || update['chat_member']
        observed = observed_time(update)

        if message
          message_envelope(update_id, message, observed)
        elsif callback
          callback_envelope(update_id, callback, observed)
        elsif member
          membership_envelope(update_id, member, observed)
        else
          unsupported_envelope(update_id, observed)
        end
      end

      private

      def observed_time(update)
        timestamp = update.dig('message', 'date') ||
                    update.dig('callback_query', 'message', 'date') ||
                    update.dig('my_chat_member', 'date') ||
                    update.dig('chat_member', 'date')
        return Time.now.utc unless timestamp

        Time.at(timestamp.to_i).utc
      end

      def message_envelope(update_id, message, observed)
        chat = message.fetch('chat')
        from = message.fetch('from')
        envelope(
          update_id:, kind: text_kind(message['text']),
          digest_fields: message_digest_fields(update_id, message, chat, from),
          text: message['text'],
          correspondent_id: "telegram:user:#{from.fetch('id')}",
          conversation_id: chat_id(chat),
          message_id: message['message_id'],
          reply_to: message.dig('reply_to_message', 'message_id'),
          observed_at: observed
        )
      end

      def callback_envelope(update_id, callback, observed)
        message = callback.fetch('message')
        envelope(
          update_id:, kind: 'callback',
          digest_fields: [update_id, 'callback_query', callback['id'], callback['data'],
                          message['message_id'], callback.dig('from', 'id')],
          text: callback['data'].to_s,
          correspondent_id: "telegram:user:#{callback.fetch('from').fetch('id')}",
          conversation_id: chat_id(message.fetch('chat')),
          callback_message_id: message.fetch('message_id'),
          callback_query_id: callback['id'].to_s,
          observed_at: observed
        )
      end

      def membership_envelope(update_id, member, observed)
        chat = member.fetch('chat')
        from = member['from'] || {}
        envelope(
          update_id:, kind: 'membership',
          digest_fields: [update_id, 'membership', chat.fetch('id'), from.fetch('id', 0)],
          text: nil,
          correspondent_id: "telegram:user:#{from.fetch('id', 0)}",
          conversation_id: chat_id(chat),
          observed_at: observed
        )
      end

      def unsupported_envelope(update_id, observed)
        envelope(
          update_id:, kind: 'unsupported', digest_fields: [update_id], text: nil,
          correspondent_id: 'telegram:user:0', conversation_id: 'telegram:chat:0',
          observed_at: observed
        )
      end

      # Message and command updates hash the same meaningful shape; the kind
      # split is admission's concern, not the payload digest's.
      def message_digest_fields(update_id, message, chat, from)
        [update_id, 'message', chat.fetch('id'), from.fetch('id'), message['message_id'],
         message['date'], message['text'], message.dig('reply_to_message', 'message_id')]
      end

      # :reek:LongParameterList -- the normalized envelope binds every fact
      #   design §6.2 makes durable.
      # rubocop:disable Metrics/ParameterLists
      def envelope(update_id:, kind:, digest_fields:, text:, correspondent_id:,
                   conversation_id:, observed_at:, reply_to: nil,
                   callback_message_id: nil, callback_query_id: nil, message_id: nil)
        Comms::InboundEnvelope.new(
          surface_id: @surface_id, surface_revision: @surface_revision, update_id:,
          raw_payload_hash: digest(digest_fields), parser_version: PARSER_VERSION,
          kind:, correspondent_id:, conversation_id:, reply_to:, callback_message_id:,
          callback_query_id:,
          message_id:, text:, observed_time: observed_at
        )
      end
      # rubocop:enable Metrics/ParameterLists

      def text_kind(text)
        return 'command' if text&.start_with?('/')

        text ? 'text' : 'unsupported'
      end

      def chat_id(chat)
        type = chat.fetch('type')
        prefix = TYPES.fetch(type, 'telegram:chat:')
        "#{prefix}#{chat.fetch('id')}"
      end

      # The store only retains the payload hash, never raw update JSON; the
      # hash covers the MEANINGFUL normalized content, so identical bytes
      # collide identically and any content change under one update_id is a
      # detectable integrity conflict (invariant 1).
      def digest(fields)
        ::Digest::SHA256.hexdigest("#{DIGEST_DOMAIN}\n#{JSON.generate(fields)}")
      end
    end
  end
end
