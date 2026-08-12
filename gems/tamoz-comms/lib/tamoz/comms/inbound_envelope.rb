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
    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # The envelope is one validated value; the smells below are the
    # per-field rule set and the fifteen facts a normalized update binds
    # (design §6.2) — splitting them would fragment the row.
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:FeatureEnvy
    # :reek:NilCheck, :reek:DataClump
    class InboundEnvelope
      KINDS = %w[text command callback membership unsupported].freeze
      MAX_ID_BYTES = 256
      MAX_TEXT_BYTES = 8192
      MAX_FIELD_BYTES = 4096

      attr_reader :surface_id, :surface_revision, :update_id, :raw_payload_hash,
                  :parser_version, :kind, :correspondent_id, :conversation_id,
                  :reply_to, :callback_message_id, :text, :command, :arguments,
                  :platform_time, :observed_time, :ingestion_time

      def initialize(
        surface_id:, surface_revision:, update_id:, raw_payload_hash:,
        parser_version:, kind:, correspondent_id:, conversation_id:,
        reply_to: nil, callback_message_id: nil, text: nil, command: nil, arguments: nil,
        platform_time: nil, observed_time: nil, ingestion_time: nil
      )
        validate!(surface_id:, surface_revision:, update_id:, raw_payload_hash:,
                  parser_version:, kind:, correspondent_id:, conversation_id:,
                  reply_to:, callback_message_id:, text:, command:, arguments:,
                  platform_time:, observed_time:, ingestion_time:)
        @surface_id = surface_id
        @surface_revision = surface_revision
        @update_id = update_id
        @raw_payload_hash = raw_payload_hash
        @parser_version = parser_version
        @kind = kind
        @correspondent_id = correspondent_id
        @conversation_id = conversation_id
        @reply_to = reply_to
        @callback_message_id = callback_message_id
        @text = text
        @command = command
        @arguments = arguments
        @platform_time = platform_time
        @observed_time = observed_time
        @ingestion_time = ingestion_time
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
          'reply_to' => @reply_to,
          'callback_message_id' => @callback_message_id,
          'text' => @text,
          'command' => @command,
          'arguments' => @arguments,
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
          reply_to: wire['reply_to'],
          callback_message_id: wire['callback_message_id'],
          text: wire['text'],
          command: wire['command'],
          arguments: wire['arguments'],
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

      private

      def validate!(
        surface_id:, surface_revision:, update_id:, raw_payload_hash:,
        parser_version:, kind:, correspondent_id:, conversation_id:,
        reply_to:, callback_message_id:, text:, command:, arguments:,
        platform_time:, observed_time:, ingestion_time:
      )
        validate_identity!(surface_id:, surface_revision:, update_id:,
                           raw_payload_hash:, parser_version:, kind:,
                           correspondent_id:, conversation_id:, reply_to:,
                           callback_message_id:, text:)
        validate_command_fields!(command:, arguments:)
        validate_times!(platform_time:, observed_time:, ingestion_time:)
      end

      def validate_identity!(
        surface_id:, surface_revision:, update_id:, raw_payload_hash:,
        parser_version:, kind:, correspondent_id:, conversation_id:,
        reply_to:, callback_message_id:, text:
      )
        unless Shapes.bounded_string?(surface_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'surface_id must be a bounded string'
        end
        unless surface_revision.is_a?(Integer) && surface_revision.positive?
          raise ValidationError, 'surface_revision must be a positive integer'
        end
        unless Shapes.bounded_integer?(update_id, max: 9_999_999_999_999_999)
          raise ValidationError, 'update_id must be a bounded integer'
        end
        raise ValidationError, 'raw_payload_hash must be a 64-char hex digest' unless Shapes.hex?(raw_payload_hash)
        unless parser_version.is_a?(Integer) && parser_version.positive?
          raise ValidationError, 'parser_version must be a positive integer'
        end
        raise ValidationError, "kind must be one of #{KINDS.join(', ')}" unless Shapes.member?(kind, KINDS)
        unless Shapes.bounded_string?(correspondent_id, max_bytes: MAX_ID_BYTES) &&
               correspondent_id.start_with?('telegram:user:')
          raise ValidationError, 'correspondent_id must be a bound telegram user id'
        end
        unless Shapes.bounded_string?(conversation_id, max_bytes: MAX_ID_BYTES) &&
               conversation_id.start_with?('telegram:chat:', 'telegram:group:',
                                           'telegram:supergroup:', 'telegram:channel:')
          raise ValidationError, 'conversation_id must be a bound telegram chat id'
        end
        if !reply_to.nil? && !Shapes.bounded_integer?(reply_to, max: 9_999_999_999_999_999)
          raise ValidationError, 'reply_to must be a bounded integer'
        end
        if !callback_message_id.nil? && !Shapes.bounded_integer?(callback_message_id, max: 9_999_999_999_999_999)
          raise ValidationError, 'callback_message_id must be a bounded integer'
        end
        return if text.nil? || Shapes.bounded_string?(text, max_bytes: MAX_TEXT_BYTES)

        raise ValidationError, 'text must be a bounded string'
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

      def validate_times!(platform_time:, observed_time:, ingestion_time:)
        [platform_time, observed_time, ingestion_time].each do |value|
          next if value.nil? || value.is_a?(Time)

          raise ValidationError, 'envelope times must be Time values'
        end
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
