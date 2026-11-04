# frozen_string_literal: true

module Tamoz
  module Mcp
    MAX_CATALOG_ENTRIES = 256
    MAX_DESCRIPTION_BYTES = 4096
    MAX_OUTPUT_BYTES = 64 * 1024
    BUDGET_DEFAULTS = {
      max_catalog_entries: 256, max_description_bytes: 4096, max_output_bytes: MAX_OUTPUT_BYTES,
      connect_timeout: 10.0, request_timeout: 30.0, max_concurrent: 4, idle_timeout: 300.0,
      max_lifetime: 3600.0, stderr_bytes: 8 * 1024
    }.freeze

    Budgets = Data.define(
      :max_catalog_entries, :max_description_bytes, :max_output_bytes,
      :connect_timeout, :request_timeout, :max_concurrent, :idle_timeout,
      :max_lifetime, :stderr_bytes
    ) do
      def initialize(**budgets)
        values = BUDGET_DEFAULTS.merge(budgets)
        bounded_integer!('max_catalog_entries', values[:max_catalog_entries], MAX_CATALOG_ENTRIES)
        bounded_integer!('max_description_bytes', values[:max_description_bytes], MAX_DESCRIPTION_BYTES)
        bounded_integer!('max_output_bytes', values[:max_output_bytes], MAX_OUTPUT_BYTES)
        %i[connect_timeout request_timeout idle_timeout max_lifetime].each { |key| positive_finite!(key, values[key]) }
        %i[max_concurrent stderr_bytes].each { |name| positive_integer!(name, values[name]) }

        super(**values)
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
