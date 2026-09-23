# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Estimates request tokens. A provider-reported prompt size for an earlier
    # request in the same series calibrates the estimate: reported tokens for the
    # shared prefix plus a heuristic for what was appended since.
    module TokenMeter
      BYTES_PER_TOKEN = 4
      MESSAGE_OVERHEAD = 4
      CALIBRATION_DOMAIN = "tamoz.context.calibration.v1\n"

      # A provider-reported prompt size for a known message prefix.
      Calibration = Data.define(:message_count, :prefix_digest, :prompt_tokens) do
        def to_h
          { 'message_count' => message_count, 'prefix_digest' => prefix_digest,
            'prompt_tokens' => prompt_tokens }
        end

        def self.from_h(value)
          return nil unless value

          new(message_count: value.fetch('message_count'), prefix_digest: value.fetch('prefix_digest'),
              prompt_tokens: value.fetch('prompt_tokens'))
        end
      end

      module_function

      def heuristic(value) = (Tamoz::Core.jcs(value).bytesize / BYTES_PER_TOKEN) + MESSAGE_OVERHEAD

      def messages_heuristic(messages) = messages.sum { |message| heuristic(message) }

      def estimate(messages:, tools:, calibration: nil)
        if calibration && messages.length >= calibration.message_count &&
           prefix_digest(messages.first(calibration.message_count), tools) == calibration.prefix_digest
          return calibration.prompt_tokens + messages_heuristic(messages.drop(calibration.message_count))
        end

        messages_heuristic(messages) + heuristic(tools)
      end

      def calibrate(messages:, tools:, prompt_tokens:)
        Calibration.new(message_count: messages.length, prefix_digest: prefix_digest(messages, tools), prompt_tokens:)
      end

      def prefix_digest(messages,
                        tools)
        Tamoz::Core.digest(CALIBRATION_DOMAIN, { 'messages' => messages, 'tools' => tools })
      end
    end
  end
end
