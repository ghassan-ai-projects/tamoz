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
    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # The delivery is one validated value; the smells below are the
    # per-field rule set and the thirteen facts one outbound effect binds
    # (design §6.3) — splitting them would fragment the outbox row.
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:NilCheck
    # :reek:BooleanParameter -- `journaled` is part of the delivery contract.
    class Delivery
      KINDS = %w[accepted answer approval_request failed stopped blocked control].freeze
      OPERATIONS = %w[send_message edit_message].freeze
      DIGEST_DOMAIN = 'tamoz.comms.delivery.v1'
      MAX_TEXT_BYTES = 4096
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

      def validate!(
        delivery_id:, conversation_id:, reply_to:, kind:, operation:, text:,
        part_index:, part_count:, markup:, journaled:, content_digest:,
        render_version:, expires_at:
      )
        raise ValidationError, 'delivery_id must be a 64-char hex digest' unless Shapes.hex?(delivery_id)
        unless Shapes.bounded_string?(conversation_id, max_bytes: 256)
          raise ValidationError, 'conversation_id must be a bounded string'
        end
        unless reply_to.nil? || Shapes.bounded_integer?(reply_to, max: 9_999_999_999_999_999)
          raise ValidationError, 'reply_to must be a bounded integer'
        end
        raise ValidationError, "kind must be one of #{KINDS.join(', ')}" unless Shapes.member?(kind, KINDS)
        raise ValidationError, "operation must be one of #{OPERATIONS.join(', ')}" unless Shapes.member?(operation,
                                                                                                         OPERATIONS)
        unless Shapes.bounded_string?(text, max_bytes: MAX_TEXT_BYTES)
          raise ValidationError, 'text must be a bounded string'
        end
        unless part_index.is_a?(Integer) && part_index >= 0
          raise ValidationError, 'part_index must be a non-negative integer'
        end
        raise ValidationError, 'part_count must be positive' unless part_count.is_a?(Integer) && part_count.positive?
        raise ValidationError, 'part_index must be below part_count' unless part_index < part_count
        if !markup.nil? && !Shapes.bounded_string?(markup, max_bytes: MAX_MARKUP_BYTES)
          raise ValidationError, 'markup must be a bounded string'
        end
        raise ValidationError, 'journaled must be a boolean' unless [true, false].include?(journaled)
        raise ValidationError, 'content_digest must be a 64-char hex digest' unless Shapes.hex?(content_digest)
        unless render_version.is_a?(Integer) && render_version.positive?
          raise ValidationError,
                'render_version must be a positive integer'
        end
        return if expires_at.nil? || expires_at.is_a?(Time)

        raise ValidationError, 'expires_at must be a Time value'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
