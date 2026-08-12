# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Graph
    # Canonical digest rule for graph definitions and checkpoint identities.
    # Version 2 is RFC 8785 (JCS) via Tamoz::Core, so definition digests agree
    # with the shared contract package (CONTRACTS.md §2-3). Version 1 used the
    # local sort + JSON.generate rule; a checkpoint carrying the older version
    # in its digest_version column was sealed under that rule.
    module Canonical
      DIGEST_VERSION = 2

      module_function

      def json(value)
        Tamoz::Core.jcs(value)
      end

      def digest(value, domain:)
        unless domain.is_a?(String) && domain.end_with?("\n")
          raise GraphDefinitionError, "Canonical digest domain must end with a newline"
        end

        Tamoz::Core.digest(domain, value)
      end
    end

    private_constant :Canonical
  end
end
