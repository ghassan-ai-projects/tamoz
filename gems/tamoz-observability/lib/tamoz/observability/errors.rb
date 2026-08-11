# frozen_string_literal: true

module Tamoz
  module Observability
    class ObservabilityError < StandardError
    end

    class ValidationError < ObservabilityError
    end

    # A lookup or emission named a signal the closed catalog does not know.
    class UnregisteredSignalError < ObservabilityError
    end

    # The same name was registered twice with an identical definition.
    class DuplicateSignalError < ObservabilityError
    end

    # An attribute set changed without a `since` bump — the catalog is the
    # compatibility surface, so silent schema drift is a load-time failure.
    class SchemaEvolutionError < ObservabilityError
    end
  end
end
