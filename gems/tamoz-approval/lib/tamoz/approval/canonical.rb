# frozen_string_literal: true

require 'digest'
require 'tamoz/core'

module Tamoz
  module Approval
    # The one digest recipe for this gem: SHA-256 over the RFC 8785
    # canonicalization homed in tamoz-core (CONTRACTS.md §2-3). Decision ids,
    # argv/targets digests, and any durable comparison go through here.
    module Canonical
      module_function

      def hexdigest(value)
        Digest::SHA256.hexdigest(Tamoz::Core.jcs(value))
      end
    end
  end
end
