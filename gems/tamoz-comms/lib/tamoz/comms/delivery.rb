# frozen_string_literal: true

require 'time'

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    # One outbound rendering, appended to the outbox by whoever produced it
    # and executed by the gateway (design §6.3). The id is derived — never
    # random — over identity, part index, render version and content digest, so
    # a crash between "decide to deliver" and "append to outbox" cannot produce
    # two rows, and a different rendering under the same logical id is a typed
    # conflict rather than an overwrite.
    #
    # The delivery's thirteen fields ARE the value; splitting them would
    # fragment the row the store persists.
    # rubocop:disable Metrics/ParameterLists
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:NilCheck
    # :reek:BooleanParameter -- `journaled` is part of the delivery contract.
    class Delivery
      KINDS = %w[answer approval_request failed stopped blocked control].freeze
      OPERATIONS = %w[send_message edit_message].freeze
      DIGEST_DOMAIN = 'tamoz.comms.delivery.v1'
      # A part is at most 4096 characters (the renderer's ceiling), and a character is up to four bytes.
      MAX_TEXT_BYTES = 16_384
      MAX_TEXT_CHARACTERS = 4096
      MAX_MARKUP_BYTES = 8192

      # @!attribute [r] reply_to
      #   The platform message id this delivery targets: the message being
      #   replied to when operation is 'send_message', or the message being
      #   edited in place when operation is 'edit_message'.
      attr_reader :delivery_id, :conversation_id, :reply_to, :kind, :operation,
                  :text, :part_index, :part_count, :markup, :journaled,
                  :content_digest, :render_version, :expires_at

      def initialize(
        delivery_id:, conversation_id:, kind:, operation:, text:, part_index:,
        part_count:, journaled:, content_digest:, render_version:,
        reply_to: nil, markup: nil, expires_at: nil
      )
        validate!(delivery_id:, conversation_id:, reply_to:, kind:, operation:,
                  text:, part_index:, part_count:, markup:, journaled:,
                  content_digest:, render_version:, expires_at:)
        @delivery_id = delivery_id
        @conversation_id = conversation_id
        @reply_to = reply_to
        @kind = kind
        @operation = operation
        @text = text
        @part_index = part_index
        @part_count = part_count
        @markup = markup&.freeze
        @journaled = journaled
        @content_digest = content_digest
        @render_version = render_version
        @expires_at = expires_at
        freeze
      end

      # Builds a delivery and derives its content-addressed id.
      # @param render_version [Integer] the rendering contract version.
      # @param content_digest [String] exact outbound bytes digest.
      def self.build(
        conversation_id:, kind:, text:, render_version:, content_digest:,
        reply_to: nil, operation: 'send_message', part_index: 0, part_count: 1,
        markup: nil, journaled: true, expires_at: nil, identity_key: nil
      )
        unless identity_key.nil? || Shapes.bounded_string?(identity_key, max_bytes: 256)
          raise ValidationError, 'identity_key must be a bounded string'
        end

        identity = [conversation_id, reply_to, part_index, render_version, content_digest]
        identity << identity_key unless identity_key.nil?
        delivery_id = Canonical.hexdigest(
          DIGEST_DOMAIN,
          identity
        )
        new(delivery_id:, conversation_id:, reply_to:, kind:, operation:,
            text:, part_index:, part_count:, markup:, journaled:,
            content_digest:, render_version:, expires_at:)
      end

      def wire
        {
          'delivery_id' => @delivery_id,
          'conversation_id' => @conversation_id,
          'reply_to' => @reply_to,
          'kind' => @kind,
          'operation' => @operation,
          'text' => @text,
          'part_index' => @part_index,
          'part_count' => @part_count,
          'markup' => @markup,
          'journaled' => @journaled,
          'content_digest' => @content_digest,
          'render_version' => @render_version,
          'expires_at' => @expires_at&.iso8601(6)
        }
      end

      def self.from_wire(wire)
        new(
          delivery_id: wire.fetch('delivery_id'),
          conversation_id: wire.fetch('conversation_id'),
          reply_to: wire['reply_to'],
          kind: wire.fetch('kind'),
          operation: wire.fetch('operation'),
          text: wire.fetch('text'),
          part_index: wire.fetch('part_index'),
          part_count: wire.fetch('part_count'),
          markup: wire['markup'],
          journaled: wire.fetch('journaled'),
          content_digest: wire.fetch('content_digest'),
          render_version: wire.fetch('render_version'),
          expires_at: wire['expires_at'] && Time.parse(wire['expires_at'])
        )
      end

      def ephemeral? = !expires_at.nil?

      private

      def validate!(**fields)
        validate_addressing!(fields)
        validate_text!(fields.fetch(:text))
        validate_parts!(fields.fetch(:part_index), fields.fetch(:part_count))
        validate_rendering!(fields)
        validate_versioning!(fields.fetch(:render_version), fields.fetch(:expires_at))
      end

      def validate_addressing!(fields)
        raise ValidationError, 'delivery_id must be a 64-char hex digest' unless Shapes.hex?(fields.fetch(:delivery_id))
        unless Shapes.bounded_string?(fields.fetch(:conversation_id), max_bytes: 256)
          raise ValidationError, 'conversation_id must be a bounded string'
        end

        reply_to = fields.fetch(:reply_to)
        unless reply_to.nil? || Shapes.bounded_integer?(reply_to, max: 9_999_999_999_999_999)
          raise ValidationError, 'reply_to must be a bounded integer'
        end
        raise ValidationError, "kind must be one of #{KINDS.join(', ')}" unless Shapes.member?(fields[:kind], KINDS)
        return if Shapes.member?(fields.fetch(:operation), OPERATIONS)

        raise ValidationError, "operation must be one of #{OPERATIONS.join(', ')}"
      end

      def validate_text!(text)
        return if Shapes.bounded_string?(text, max_bytes: MAX_TEXT_BYTES) && text.length <= MAX_TEXT_CHARACTERS

        raise ValidationError, 'text must be a bounded string'
      end

      def validate_parts!(part_index, part_count)
        unless part_index.is_a?(Integer) && part_index >= 0
          raise ValidationError, 'part_index must be a non-negative integer'
        end
        raise ValidationError, 'part_count must be positive' unless part_count.is_a?(Integer) && part_count.positive?
        raise ValidationError, 'part_index must be below part_count' unless part_index < part_count
      end

      def validate_rendering!(fields)
        markup = fields.fetch(:markup)
        if !markup.nil? && !Shapes.bounded_string?(markup, max_bytes: MAX_MARKUP_BYTES)
          raise ValidationError, 'markup must be a bounded string'
        end
        raise ValidationError, 'journaled must be a boolean' unless [true, false].include?(fields.fetch(:journaled))
        return if Shapes.hex?(fields.fetch(:content_digest))

        raise ValidationError, 'content_digest must be a 64-char hex digest'
      end

      def validate_versioning!(render_version, expires_at)
        unless render_version.is_a?(Integer) && render_version.positive?
          raise ValidationError, 'render_version must be a positive integer'
        end
        return if expires_at.nil? || expires_at.is_a?(Time)

        raise ValidationError, 'expires_at must be a Time value'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
