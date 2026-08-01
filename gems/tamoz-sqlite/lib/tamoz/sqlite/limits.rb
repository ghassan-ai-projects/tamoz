# frozen_string_literal: true

module Tamoz
  module SQLite
    Limits = Data.define(
      :pool_size,
      :busy_timeout,
      :checkout_timeout,
      :retry_limit,
      :retry_base_delay,
      :operation_timeout,
      :wal_autocheckpoint_pages,
      :lease_ttl,
      :effect_attempt_ttl,
      :clock_rollback_tolerance_ms,
      :deletion_retention
    ) do
      MAX_POOL_SIZE = 64
      MAX_TIMEOUT = 60.0
      MAX_RETRY_LIMIT = 100
      MAX_WAL_PAGES = 1_000_000
      MAX_LEASE_TTL = 3600.0
      MIN_EFFECT_ATTEMPT_TTL = 0.1
      MAX_EFFECT_ATTEMPT_TTL = 3600.0
      MAX_CLOCK_TOLERANCE_MS = 60_000
      MAX_DELETION_RETENTION = 31_536_000.0

      def initialize(
        pool_size: 4,
        busy_timeout: 0.25,
        checkout_timeout: 1.0,
        retry_limit: 5,
        retry_base_delay: 0.005,
        operation_timeout: 5.0,
        wal_autocheckpoint_pages: 1_000,
        lease_ttl: 30.0,
        effect_attempt_ttl: 60.0,
        clock_rollback_tolerance_ms: 1_000,
        deletion_retention: 86_400.0
      )
        validate_integer!(pool_size, :pool_size, 1, MAX_POOL_SIZE)
        validate_number!(busy_timeout, :busy_timeout, 0.0, MAX_TIMEOUT)
        validate_number!(checkout_timeout, :checkout_timeout, 0.001, MAX_TIMEOUT)
        validate_integer!(retry_limit, :retry_limit, 0, MAX_RETRY_LIMIT)
        validate_number!(retry_base_delay, :retry_base_delay, 0.0, 1.0)
        validate_number!(operation_timeout, :operation_timeout, 0.001, MAX_TIMEOUT)
        if busy_timeout > operation_timeout || checkout_timeout > operation_timeout
          raise ConfigurationError,
                "busy_timeout and checkout_timeout cannot exceed operation_timeout"
        end
        validate_integer!(
          wal_autocheckpoint_pages,
          :wal_autocheckpoint_pages,
          1,
          MAX_WAL_PAGES
        )
        validate_number!(lease_ttl, :lease_ttl, 0.1, MAX_LEASE_TTL)
        validate_number!(
          effect_attempt_ttl,
          :effect_attempt_ttl,
          MIN_EFFECT_ATTEMPT_TTL,
          MAX_EFFECT_ATTEMPT_TTL
        )
        validate_integer!(
          clock_rollback_tolerance_ms,
          :clock_rollback_tolerance_ms,
          0,
          MAX_CLOCK_TOLERANCE_MS
        )
        validate_number!(
          deletion_retention,
          :deletion_retention,
          0.0,
          MAX_DELETION_RETENTION
        )

        super
      end

      private

      def validate_integer!(value, name, minimum, maximum)
        return if value.is_a?(Integer) && value.between?(minimum, maximum)

        raise ConfigurationError,
              "#{name} must be between #{minimum} and #{maximum}"
      end

      def validate_number!(value, name, minimum, maximum)
        return if value.is_a?(Numeric) &&
                  value.finite? &&
                  value >= minimum &&
                  value <= maximum

        raise ConfigurationError,
              "#{name} must be between #{minimum} and #{maximum}"
      end

    end
  end
end
