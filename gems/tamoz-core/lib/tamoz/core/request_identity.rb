# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Core
    # The durable request identity of one inbound channel update (plan 02,
    # work item 2): SHA256 over the domain, a newline, and the JSON array of
    # the identity fields. Both the store that anchors the row and the gateway
    # that acknowledges the update derive it from this one definition, so an
    # acknowledgement can name the reference with no store round-trip.
    module RequestIdentity
      DOMAIN = 'tamoz.comms.request.v1'

      module_function

      def request_id(surface_id:, surface_revision:, bot_id:, update_id:, raw_payload_hash:)
        ::Digest::SHA256.hexdigest(
          "#{DOMAIN}\n" +
          JSON.generate([surface_id, surface_revision, bot_id, update_id, raw_payload_hash])
        )
      end
    end
  end
end
