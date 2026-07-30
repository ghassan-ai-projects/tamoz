# frozen_string_literal: true

module Tamoz
  module TaskResult
    module Validation
      module_function

      def index(value)
        return value if value.is_a?(Integer) && !value.negative?

        raise ConfigurationError, "task result index must be a non-negative integer"
      end

      def reason(value)
        SafeText.normalize(
          value,
          name: "task result reason",
          max_bytes: 256,
          error_class: ConfigurationError
        )
      end
    end

    Succeeded = Data.define(:index, :value) do
      def initialize(index:, value:)
        super(index: Validation.index(index), value:)
      end

      def status = :succeeded
    end

    Failed = Data.define(:index, :error) do
      def initialize(index:, error:)
        raise ConfigurationError, "failed task result requires an Exception" unless error.is_a?(Exception)

        super(index: Validation.index(index), error:)
      end

      def status = :failed
    end

    Fatal = Data.define(:index, :error) do
      def initialize(index:, error:)
        unless error.is_a?(Exception) && error.is_a?(FatalRuntimeFailure)
          raise ConfigurationError,
                "fatal task result requires a Tamoz::FatalRuntimeFailure"
        end

        super(index: Validation.index(index), error:)
      end

      def status = :fatal
    end

    Interrupted = Data.define(:index, :descriptor) do
      def initialize(index:, descriptor:)
        super(index: Validation.index(index), descriptor: Immutable.copy(descriptor))
      end

      def status = :interrupted
    end

    Cancelled = Data.define(:index, :reason) do
      def initialize(index:, reason:)
        super(index: Validation.index(index), reason: Validation.reason(reason))
      end

      def status = :cancelled
    end

    Stuck = Data.define(:index, :worker_name) do
      def initialize(index:, worker_name:)
        super(
          index: Validation.index(index),
          worker_name: Validation.reason(worker_name)
        )
      end

      def status = :stuck
    end

    private_constant :Validation
  end
end
