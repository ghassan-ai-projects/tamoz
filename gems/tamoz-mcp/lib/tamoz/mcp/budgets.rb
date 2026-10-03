# frozen_string_literal: true

module Tamoz
  module Mcp
    Budgets = Data.define(
      :max_catalog_entries, :max_description_bytes, :max_output_bytes,
      :connect_timeout, :request_timeout, :max_concurrent, :idle_timeout,
      :max_lifetime, :stderr_bytes
    ) do
      MAX_CATALOG_ENTRIES = 256
      MAX_DESCRIPTION_BYTES = 4096
      MAX_OUTPUT_BYTES = 64 * 1024

      def initialize(
        max_catalog_entries: 256,
        max_description_bytes: 4096,
        max_output_bytes: MAX_OUTPUT_BYTES,
        connect_timeout: 10.0,
        request_timeout: 30.0,
        max_concurrent: 4,
        idle_timeout: 300.0,
        max_lifetime: 3600.0,
        stderr_bytes: 8 * 1024
      )
        bounded_integer!('max_catalog_entries', max_catalog_entries, MAX_CATALOG_ENTRIES)
        bounded_integer!('max_description_bytes', max_description_bytes, MAX_DESCRIPTION_BYTES)
        bounded_integer!('max_output_bytes', max_output_bytes, MAX_OUTPUT_BYTES)
        positive_finite!('connect_timeout', connect_timeout)
        positive_finite!('request_timeout', request_timeout)
        positive_finite!('idle_timeout', idle_timeout)
        positive_finite!('max_lifetime', max_lifetime)
        positive_integer!('max_concurrent', max_concurrent)
        positive_integer!('stderr_bytes', stderr_bytes)

        super
      end

      private

      def bounded_integer!(name, value, cap)
        return if value.is_a?(Integer) && value >= 1 && value <= cap

        raise ValidationError, "budgets.#{name} must be an integer between 1 and #{cap}"
      end

      def positive_finite!(name, value)
        return if value.is_a?(Numeric) && value.finite? && value.positive?

        raise ValidationError, "budgets.#{name} must be positive and finite"
      end

      def positive_integer!(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise ValidationError, "budgets.#{name} must be a positive integer"
      end
    end
  end
end
