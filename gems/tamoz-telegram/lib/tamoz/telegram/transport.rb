# frozen_string_literal: true

require 'json'

module Tamoz
  module Telegram
    # The Tamoz::Comms::Transport seam over the Telegram Bot API (design
    # §6.4). `authenticate` is getMe; `poll` is getUpdates with the supplied
    # candidate next_offset (confirming the prior durable prefix remotely);
    # `deliver` is exactly one sendMessage/editMessageText — a timeout on a
    # send becomes AmbiguousDeliveryError, never a blind retry; `signal` is
    # answerCallbackQuery (ephemeral, unjournaled).
    #
    # This class must pass the tamoz-comms conformance suite (slice F exit):
    # the fixture server can duplicate/reorder/throttle/lose/time out.
    # The transport is the four-method seam; the metric smells measure the
    # seam (poll params, deliver mapping), not a choice to overload.
    # :reek:UtilityFunction, :reek:DuplicateMethodCall, :reek:ControlParameter
    class Transport
      include Comms::Transport

      def initialize(client:, normalizer:)
        @client = client
        @normalizer = normalizer
      end

      # @return [Hash] the authenticated surface identity (getMe result).
      def authenticate(_descriptor, _credential)
        @client.call('getMe', {}, idempotent: true)
      end

      # @return [Hash] `{updates: [wire envelopes], next_offset: Integer}`
      # :reek:TooManyStatements, :reek:NilCheck -- the poll builds params,
      #   normalizes the batch and derives the candidate offset.
      def poll(next_offset:, limit:, timeout_s:)
        allowed = %w[message callback_query my_chat_member]
        params = { 'timeout' => timeout_s, 'limit' => limit, 'allowed_updates' => allowed }
        params['offset'] = next_offset unless next_offset.nil?
        result = @client.call('getUpdates', params, idempotent: true)
        updates = result.map { |update| @normalizer.normalize(update).wire }
        candidate = result.map { |update| update.fetch('update_id') }.max
        { updates:, next_offset: candidate && (candidate + 1) }
      end

      # @return [Hash] `{message_id:, platform_time:}`
      # :reek:FeatureEnvy, :reek:TooManyStatements -- the send maps one
      #   Delivery to one API effect.
      def deliver(delivery)
        params = {
          'chat_id' => chat_id(delivery.conversation_id),
          'text' => delivery.text
        }
        editing = delivery.operation == 'edit_message'
        if editing
          params['message_id'] = delivery.reply_to
        elsif delivery.reply_to
          params['reply_to_message_id'] = delivery.reply_to
        end
        attach_markup(params, delivery) if delivery.markup
        result = @client.call(editing ? 'editMessageText' : 'sendMessage', params)
        {
          'message_id' => result.fetch('message_id'),
          'platform_time' => Time.at(result.fetch('date')).utc.iso8601(6)
        }
      end

      def signal(kind, **fields)
        return :unsupported unless kind == :ack

        @client.call('answerCallbackQuery', { 'callback_query_id' => fields.fetch(:callback_query_id) })
        :acked
      end

      private

      # v2 approve+deny (ADR-043 v1 was deny-only): the control delivery's
      # markup carries the single-use reference plus the actions; each button's
      # callback data encodes `action:reference` so a press resolves exactly
      # one ACTIVE prompt in the direction the operator chose. A bare
      # reference (v1 wire) still resolves as deny.
      def attach_markup(params, delivery)
        markup = JSON.parse(delivery.markup)
        reference = markup.fetch('reference')
        actions = markup.fetch('actions', %w[deny])
        params['reply_markup'] = {
          'inline_keyboard' => [actions.map do |action|
            { 'text' => action.capitalize, 'callback_data' => "#{action}:#{reference}" }
          end]
        }
      end

      def chat_id(conversation_id)
        conversation_id.delete_prefix('telegram:chat:')
                       .delete_prefix('telegram:group:')
                       .delete_prefix('telegram:supergroup:')
                       .delete_prefix('telegram:channel:')
      end
    end
  end
end
