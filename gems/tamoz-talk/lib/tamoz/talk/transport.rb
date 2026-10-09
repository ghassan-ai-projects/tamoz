# frozen_string_literal: true

module Tamoz
  module Talk
    # The Tamoz::Comms::Transport seam over the talk hub; the poller and the drainer each hold one on the same hub.
    class Transport
      include Comms::Transport

      def initialize(hub)
        @hub = hub
      end

      def authenticate(_descriptor, _credential) = { 'id' => @hub.identity_id }

      def poll(next_offset:, limit:, timeout_s:) = @hub.inbox.poll(next_offset:, limit:, timeout_s:)

      def deliver(delivery) = @hub.deliver(delivery)

      def fetch_attachment(file_id, max_bytes:)
        audio = @hub.inbox.audio(file_id)
        raise Comms::TransientTransportError, 'the recording is no longer held' unless audio
        raise Comms::ResponseTooLargeError, 'the recording exceeds the attachment limit' if audio.bytesize > max_bytes

        audio
      end

      def signal(kind, **fields)
        case kind
        when :typing then @hub.log.pulse(fields.fetch(:conversation_id)) && :typing
        when :ack then @hub.log.append('ack', 'text' => fields[:text].to_s) && :acked
        when :clear_buttons then @hub.log.append('buttons_cleared',
                                                 'message_id' => fields.fetch(:message_id)) && :cleared
        else :unsupported
        end
      end
    end
  end
end
