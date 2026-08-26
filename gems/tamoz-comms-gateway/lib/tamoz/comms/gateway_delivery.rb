# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Builds bounded outbound control deliveries and selects their reply target.
      module Delivery
        private

        # All control replies pass through one bounded delivery construction point.
        def append_control(reply_text, envelope, now:, kind: 'control')
          text = String(reply_text).scrub.byteslice(0, Comms::Delivery::MAX_TEXT_BYTES)
          delivery = Comms::Delivery.build(
            conversation_id: envelope.fetch('conversation_id'), reply_to: reply_target(envelope), kind:,
            text:, part_index: 0, part_count: 1, journaled: false,
            render_version: Comms::Rendering::RENDER_VERSION,
            content_digest: Comms::Rendering.content_digest(text)
          )
          @store.append_delivery(delivery.wire, surface_id:, capacity: control_capacity, now:)
        end

        # A control reply targets the platform message id carried by the update.
        def reply_target(envelope)
          if envelope.fetch('kind') == 'callback'
            envelope['callback_message_id'] || envelope.fetch('update_id')
          else
            envelope['message_id'] || envelope.fetch('update_id')
          end
        end
      end
    end
  end
end
