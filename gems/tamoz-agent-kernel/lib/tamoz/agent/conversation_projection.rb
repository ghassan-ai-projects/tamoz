# frozen_string_literal: true

require 'tamoz/agent/errors'
require 'tamoz/core'

module Tamoz
  module Agent
    # The journaled receipt of one tool-calling conversation turn. A replay
    # returns this record, never a fresh answer.
    # :reek:ControlParameter :reek:NilCheck :reek:TooManyStatements -- mirrors ModelCallProjection's checks.
    module ConversationProjection
      KEYS = %w[
        request_digest content tool_calls finish_reason response_digest usage
        settings_digest provider_configuration_digest
      ].freeze
      DIGESTS = %w[request_digest response_digest settings_digest provider_configuration_digest].freeze

      module_function

      def from_response(response, request_digest:)
        validate!(KEYS.to_h { |key| [key, response.public_send(key)] }, request_digest:)
      rescue ModelReceiptError, NoMethodError
        raise ModelCallError.new(code: 'invalid_projection')
      end

      def validate!(projection, request_digest: nil)
        unless projection.is_a?(Hash) && projection.keys.sort == KEYS.sort
          raise ModelReceiptError,
                'conversation_projection/shape'
        end

        DIGESTS.each { |key| ModelCall.require_digest!("conversation_projection.#{key}", projection[key]) }
        if request_digest && projection['request_digest'] != request_digest
          raise ModelReceiptError, 'conversation_projection/request_digest_mismatch'
        end

        validate_fields!(projection)
        Tamoz::Core.deep_freeze(projection)
      end

      def validate_fields!(projection)
        raise ModelReceiptError, 'conversation_projection/content' unless projection['content'].is_a?(String)
        unless projection['finish_reason'].is_a?(String)
          raise ModelReceiptError,
                'conversation_projection/finish_reason'
        end
        raise ModelReceiptError, 'conversation_projection/tool_calls' unless tool_calls?(projection['tool_calls'])
        raise ModelReceiptError, 'conversation_projection/usage' unless usage?(projection['usage'])
      end

      def tool_calls?(calls)
        calls.is_a?(Array) && calls.all? do |call|
          call.is_a?(Hash) && call.keys.sort == %w[arguments id name] && call.values.all?(String)
        end
      end

      def usage?(usage) = usage.nil? || usage.is_a?(Hash)
      private_class_method :validate_fields!, :tool_calls?, :usage?
    end
  end
end
