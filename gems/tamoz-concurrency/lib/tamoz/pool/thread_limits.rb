# frozen_string_literal: true

module Tamoz
  module Pool
    ThreadLimits = Data.define(:size, :queue_capacity, :cancellation_grace, :stuck_worker_limit) do
      def initialize(size:, queue_capacity:, cancellation_grace:, stuck_worker_limit:)
        validate_size!(size)
        validate_queue_capacity!(queue_capacity)
        validate_cancellation_grace!(cancellation_grace)
        validate_stuck_worker_limit!(size:, limit: stuck_worker_limit)
        super
      end

      private

      def validate_size!(size)
        return if size.is_a?(Integer) && size.positive? && size <= Configuration::MAX_POOL_SIZE

        raise ConfigurationError,
              "thread pool size must be between 1 and #{Configuration::MAX_POOL_SIZE}"
      end

      def validate_queue_capacity!(capacity)
        return if capacity.is_a?(Integer) && capacity.positive? && capacity <= MAX_QUEUE_CAPACITY

        raise ConfigurationError,
              "queue_capacity must be between 1 and #{MAX_QUEUE_CAPACITY}"
      end

      def validate_cancellation_grace!(grace)
        return if grace.is_a?(Numeric) && grace.finite? && !grace.negative? && grace <= 60

        raise ConfigurationError, 'cancellation_grace must be between 0 and 60 seconds'
      end

      def validate_stuck_worker_limit!(size:, limit:)
        return if limit.is_a?(Integer) && limit.positive? && limit <= size

        raise ConfigurationError, 'stuck_worker_limit must be between 1 and pool size'
      end
    end

    private_constant :ThreadLimits
  end
end
