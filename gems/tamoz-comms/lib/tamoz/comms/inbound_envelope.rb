# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    # The normalized, validated form of ONE platform update (design §6.2).
    # Transport-specific shapes collapse into this typed value before anything
    # else sees them; anything unsupported becomes a typed disposition, never a
    # turn. The update_id is a dedup key, never treated as gap-free.
    #
    # The envelope's fields ARE the value and its validation is the per-field
    # rule set; splitting either would fragment the row the store persists.
    # rubocop:disable Metrics/ParameterLists
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:FeatureEnvy
    # :reek:NilCheck, :reek:DataClump
    class InboundEnvelope
      KINDS = %w[text command callback membership attachment unsupported].freeze
      ATTACHMENT_KINDS = %w[document image voice audio].freeze
      ATTACHMENT_KEYS = %w[kind file_id file_unique_id media_type name size_bytes duration_s].freeze
      MAX_ATTACHMENT_LABEL_BYTES = 255
      MAX_ID_BYTES = 256
      MAX_ID_VALUE = 9_999_999_999_999_999
      MAX_TEXT_BYTES = 8192
      MAX_FIELD_BYTES = 4096

      attr_reader :surface_id, :surface_revision, :update_id, :raw_payload_hash,
                  :parser_version, :kind, :correspondent_id, :conversation_id,
                  :message_id, :reply_to, :callback_message_id, :callback_query_id,
                  :text, :command, :arguments, :attachment,
                  :platform_time, :observed_time, :ingestion_time

      def initialize(
        surface_id:, surface_revision:, update_id:, raw_payload_hash:,
        parser_version:, kind:, correspondent_id:, conversation_id:,
        message_id: nil, reply_to: nil, callback_message_id: nil, callback_query_id: nil,
        text: nil, command: nil, arguments: nil, attachment: nil,
        platform_time: nil, observed_time: nil, ingestion_time: nil
      )
        fields = {
          surface_id:, surface_revision:, update_id:, raw_payload_hash:, parser_version:, kind:,
          correspondent_id:, conversation_id:, message_id:, reply_to:, callback_message_id:,
          callback_query_id:, text:, command:, arguments:, attachment: attachment && Tamoz::Core.deep_freeze(attachment.dup), platform_time:,
          observed_time:, ingestion_time:
        }
        validate!(fields)
        fields.each { |name, value| instance_variable_set(:"@#{name}", value) }
        freeze
      end

      # The durable wire form. Rows never retain raw update JSON; only this
      # normalized shape (design §13).
      def wire
        {
          'surface_id' => @surface_id,
          'surface_revision' => @surface_revision,
          'update_id' => @update_id,
          'raw_payload_hash' => @raw_payload_hash,
          'parser_version' => @parser_version,
          'kind' => @kind,
          'correspondent_id' => @correspondent_id,
          'conversation_id' => @conversation_id,
          'message_id' => @message_id,
          'reply_to' => @reply_to,
          'callback_message_id' => @callback_message_id,
          'callback_query_id' => @callback_query_id,
          'text' => @text,
          'command' => @command,
          'arguments' => @arguments,
          'attachment' => @attachment,
          'platform_time' => @platform_time&.iso8601(6),
          'observed_time' => @observed_time&.iso8601(6),
          'ingestion_time' => @ingestion_time&.iso8601(6)
        }
      end

      def self.from_wire(wire)
        new(
          surface_id: wire.fetch('surface_id'),
          surface_revision: wire.fetch('surface_revision'),
          update_id: wire.fetch('update_id'),
          raw_payload_hash: wire.fetch('raw_payload_hash'),
          parser_version: wire.fetch('parser_version'),
          kind: wire.fetch('kind'),
          correspondent_id: wire.fetch('correspondent_id'),
          conversation_id: wire.fetch('conversation_id'),
          message_id: wire['message_id'],
          reply_to: wire['reply_to'],
          callback_message_id: wire['callback_message_id'],
          callback_query_id: wire['callback_query_id'],
          text: wire['text'],
          command: wire['command'],
          arguments: wire['arguments'],
          attachment: wire['attachment'],
          platform_time: wire_time(wire, 'platform_time'),
          observed_time: wire_time(wire, 'observed_time'),
          ingestion_time: wire_time(wire, 'ingestion_time')
        )
      end

      def self.wire_time(wire, key)
        value = wire[key]
        value && Time.parse(value)
      end

      def command? = kind == 'command'

      def text? = kind == 'text'

      def attachment? = kind == 'attachment'

      private

      def validate!(fields)
        validate_surface!(fields)
        validate_parties!(fields.fetch(:correspondent_id), fields.fetch(:conversation_id))
        validate_message_refs!(fields)
        validate_command_fields!(command: fields.fetch(:command), arguments: fields.fetch(:arguments))
        validate_attachment!(fields.fetch(:kind), fields.fetch(:attachment))
        validate_times!(fields.values_at(:platform_time, :observed_time, :ingestion_time))
      end

      def validate_surface!(fields)
        unless Shapes.bounded_string?(fields.fetch(:surface_id), max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'surface_id must be a bounded string'
        end

        require_positive!(fields.fetch(:surface_revision), 'surface_revision')
        unless Shapes.bounded_integer?(fields.fetch(:update_id), max: MAX_ID_VALUE)
          raise ValidationError, 'update_id must be a bounded integer'
        end
        unless Shapes.hex?(fields.fetch(:raw_payload_hash))
          raise ValidationError, 'raw_payload_hash must be a 64-char hex digest'
        end

        require_positive!(fields.fetch(:parser_version), 'parser_version')
        return if Shapes.member?(fields.fetch(:kind), KINDS)

        raise ValidationError, "kind must be one of #{KINDS.join(', ')}"
      end

      def validate_parties!(correspondent_id, conversation_id)
        Shapes.require_prefixed!(correspondent_id, Parties.correspondent_prefixes,
                                 'correspondent_id must be a bound user id', max_bytes: MAX_ID_BYTES)
        Shapes.require_prefixed!(conversation_id, Parties.admissible_prefixes,
                                 'conversation_id must be a bound chat id', max_bytes: MAX_ID_BYTES)
      end

      def validate_message_refs!(fields)
        %i[message_id reply_to callback_message_id].each { |name| optional_integer!(fields.fetch(name), name) }
        callback_query_id = fields.fetch(:callback_query_id)
        if !callback_query_id.nil? && !Shapes.bounded_string?(callback_query_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'callback_query_id must be a bounded string'
        end

        text = fields.fetch(:text)
        return if text.nil? || Shapes.bounded_string?(text, max_bytes: MAX_TEXT_BYTES)

        raise ValidationError, 'text must be a bounded string'
      end

      def require_positive!(value, name)
        raise ValidationError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      end

      def optional_integer!(value, name)
        return if value.nil? || Shapes.bounded_integer?(value, max: MAX_ID_VALUE)

        raise ValidationError, "#{name} must be a bounded integer"
      end

      def validate_command_fields!(command:, arguments:)
        if command.nil?
          return if arguments.nil?

          raise ValidationError, 'arguments without a command'
        end
        raise ValidationError, 'a command field requires kind :command' unless kind == 'command'
        unless Shapes.bounded_string?(command, max_bytes: MAX_FIELD_BYTES)
          raise ValidationError, 'command must be a bounded string'
        end
        return if arguments.nil? || Shapes.bounded_string?(arguments, max_bytes: MAX_TEXT_BYTES)

        raise ValidationError, 'arguments must be a bounded string'
      end

      def validate_attachment!(kind, attachment)
        return if attachment.nil? && kind != 'attachment'
        raise ValidationError, 'an attachment requires kind attachment and the reverse' unless
          kind == 'attachment' && attachment.is_a?(Hash) && attachment.keys.sort == ATTACHMENT_KEYS.sort

        Shapes.require_member!(attachment.fetch('kind'), ATTACHMENT_KINDS, 'attachment kind')
        %w[file_id file_unique_id].each do |key|
          Shapes.require_string!(attachment.fetch(key), "attachment #{key}", max_bytes: MAX_ID_BYTES)
        end
        %w[media_type name].each do |key|
          value = attachment.fetch(key)
          next if value.nil?

          Shapes.require_string!(value, "attachment #{key}", max_bytes: MAX_ATTACHMENT_LABEL_BYTES)
        end
        %w[size_bytes duration_s].each { |key| optional_integer!(attachment.fetch(key), "attachment #{key}") }
      end

      def validate_times!(times)
        times.each do |value|
          next if value.nil? || value.is_a?(Time)

          raise ValidationError, 'envelope times must be Time values'
        end
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
