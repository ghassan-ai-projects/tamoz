# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    InboundEnvelope = Data.define(:surface_id, :surface_revision, :update_id, :raw_payload_hash,
                                  :parser_version, :kind, :correspondent_id, :conversation_id,
                                  :message_id, :reply_to, :callback_message_id, :callback_query_id,
                                  :text, :command, :arguments, :attachment,
                                  :platform_time, :observed_time, :ingestion_time)

    # The normalized, validated form of ONE platform update (design §6.2).
    # Transport-specific shapes collapse into this typed value before anything
    # else sees them; anything unsupported becomes a typed disposition, never a
    # turn. The update_id is a dedup key, never treated as gap-free.
    #
    # :reek:MissingSafeMethod, :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:NilCheck
    class InboundEnvelope
      KINDS = %w[text command callback membership attachment unsupported].freeze
      ATTACHMENT_KINDS = %w[document image voice audio].freeze
      ATTACHMENT_KEYS = %w[kind file_id file_unique_id media_type name size_bytes duration_s].freeze
      MAX_ATTACHMENT_LABEL_BYTES = 255
      MAX_ID_BYTES = 256
      MAX_ID_VALUE = 9_999_999_999_999_999
      MAX_TEXT_BYTES = 8192
      MAX_FIELD_BYTES = 4096
      TIMES = %i[platform_time observed_time ingestion_time].freeze
      OPTIONAL = (%i[message_id reply_to callback_message_id callback_query_id text command arguments] + TIMES)
                 .to_h { |name| [name, nil] }.freeze

      def initialize(attachment: nil, **fields)
        super(**OPTIONAL, **fields, attachment: attachment && Tamoz::Core.deep_freeze(attachment.dup))
        validate!
      end

      # The durable wire form. Rows never retain raw update JSON; only this
      # normalized shape (design §13).
      def wire
        to_h.to_h { |name, value| [name.to_s, TIMES.include?(name) ? value&.iso8601(6) : value] }
      end

      def self.from_wire(wire)
        new(**members.to_h do |name|
          value = wire[name.to_s]
          [name, TIMES.include?(name) && value ? Time.parse(value) : value]
        end)
      end

      def command? = kind == 'command'

      def text? = kind == 'text'

      def attachment? = kind == 'attachment'

      private

      def validate!
        validate_surface!
        validate_parties!
        validate_message_refs!
        validate_command_fields!
        validate_attachment!
        validate_times!
      end

      def validate_surface!
        raise ValidationError, 'surface_id must be a bounded string' unless
          Shapes.bounded_string?(surface_id, max_bytes: MAX_ID_BYTES)

        Shapes.require_positive!(surface_revision, 'surface_revision')
        raise ValidationError, 'update_id must be a bounded integer' unless
          Shapes.bounded_integer?(update_id, max: MAX_ID_VALUE)
        raise ValidationError, 'raw_payload_hash must be a 64-char hex digest' unless Shapes.hex?(raw_payload_hash)

        Shapes.require_positive!(parser_version, 'parser_version')
        Shapes.require_member!(kind, KINDS, 'kind')
      end

      def validate_parties!
        unless Parties.correspondent?(correspondent_id)
          raise ValidationError,
                'correspondent_id must be a bound user id'
        end
        raise ValidationError, 'conversation_id must be a bound chat id' unless Parties.conversation?(conversation_id)
      end

      def validate_message_refs!
        { message_id:, reply_to:, callback_message_id: }.each { |name, value| optional_integer!(value, name) }
        optional_string!(callback_query_id, 'callback_query_id', MAX_ID_BYTES)
        optional_string!(text, 'text', MAX_TEXT_BYTES)
      end

      def optional_string!(value, name, max_bytes)
        Shapes.require_string!(value, name, max_bytes:) unless value.nil?
      end

      def optional_integer!(value, name)
        return if value.nil? || Shapes.bounded_integer?(value, max: MAX_ID_VALUE)

        raise ValidationError, "#{name} must be a bounded integer"
      end

      def validate_command_fields!
        if command.nil?
          return if arguments.nil?

          raise ValidationError, 'arguments without a command'
        end
        raise ValidationError, 'a command field requires kind :command' unless kind == 'command'

        Shapes.require_string!(command, 'command', max_bytes: MAX_FIELD_BYTES)
        optional_string!(arguments, 'arguments', MAX_TEXT_BYTES)
      end

      def validate_attachment!
        return if attachment.nil? && !attachment?
        raise ValidationError, 'an attachment requires kind attachment and the reverse' unless
          attachment? && attachment.is_a?(Hash) && attachment.keys.sort == ATTACHMENT_KEYS.sort

        validate_attachment_fields!(attachment)
      end

      def validate_attachment_fields!(fields)
        Shapes.require_member!(fields.fetch('kind'), ATTACHMENT_KINDS, 'attachment kind')
        %w[file_id file_unique_id].each do |key|
          Shapes.require_string!(fields.fetch(key), "attachment #{key}", max_bytes: MAX_ID_BYTES)
        end
        %w[media_type name].each do |key|
          optional_string!(fields.fetch(key), "attachment #{key}", MAX_ATTACHMENT_LABEL_BYTES)
        end
        %w[size_bytes duration_s].each { |key| optional_integer!(fields.fetch(key), "attachment #{key}") }
      end

      def validate_times!
        return if [platform_time, observed_time, ingestion_time].all? { |value| value.nil? || value.is_a?(Time) }

        raise ValidationError, 'envelope times must be Time values'
      end
    end
  end
end
