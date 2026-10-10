# frozen_string_literal: true

module Tamoz
  module Comms
    # Shared field-shape predicates for channel values (design §6). Every
    # value raises ValidationError on an ill-shaped field; these keep the
    # bound rules in one place so the envelope, surface, and delivery cannot
    # disagree about what a bounded string is.
    module Shapes
      module_function

      def bounded_string?(value, max_bytes:)
        value.is_a?(String) && !value.empty? && value.bytesize <= max_bytes
      end

      def hex?(value, bits: 256)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{#{bits / 4}}\z/)
      end

      def bounded_integer?(value, max:)
        value.is_a?(Integer) && value >= 0 && value <= max
      end

      def member?(value, set)
        set.include?(value)
      end

      def require_string!(value, name, max_bytes:)
        raise ValidationError, "#{name} must be a bounded string" unless bounded_string?(value, max_bytes:)
      end

      def require_positive!(value, name)
        raise ValidationError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      end

      def require_time!(value, name)
        raise ValidationError, "#{name} must be a Time value" unless value.is_a?(Time)
      end

      def utc(value) = value.is_a?(Time) ? value.getutc : value

      def require_member!(value, set, name)
        raise ValidationError, "#{name} must be one of #{set.join(', ')}" unless member?(value, set)
      end
    end
  end
end
