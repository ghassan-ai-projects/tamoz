# frozen_string_literal: true

module Tamoz
  module Observability
    class ObservabilityError < Tamoz::Error
      CATEGORY = "observability"
      SAFE_MESSAGE = "An observability operation failed."
    end

    class ValidationError < ObservabilityError
      CATEGORY = "observability_validation"
      SAFE_MESSAGE = "The observability value is invalid."
    end

    # A lookup or emission named a signal the closed catalog does not know.
    class UnregisteredSignalError < ObservabilityError
      CATEGORY = "observability_unregistered_signal"
      SAFE_MESSAGE = "The signal is not registered in the catalog."
    end

    # The same name was registered twice with an identical definition.
    class DuplicateSignalError < ObservabilityError
      CATEGORY = "observability_duplicate_signal"
      SAFE_MESSAGE = "The signal is already registered."
    end

    # An attribute set changed without a `since` bump — the catalog is the
    # compatibility surface, so silent schema drift is a load-time failure.
    class SchemaEvolutionError < ObservabilityError
      CATEGORY = "observability_schema_evolution"
      SAFE_MESSAGE = "The signal catalog schema changed without a version bump."
    end
  end
end
