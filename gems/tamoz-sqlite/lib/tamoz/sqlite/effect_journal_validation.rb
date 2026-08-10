# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Validates effect-journal inputs and persisted enum values.
    # :reek:DataClump -- value, allowed vocabulary, and field name travel
    # together because each refusal must name the exact effect field.
    module EffectJournalValidation
      module_function

      def enum_text!(value, allowed, name)
        text = value.to_s
        return text if allowed.include?(text)

        raise ConfigurationError, "#{name} is invalid"
      end

      def checked_symbol!(value, allowed, name)
        unless value.is_a?(String) && allowed.include?(value)
          raise CheckpointCorruptionError, "stored #{name} is invalid"
        end

        value.to_sym
      end

      def non_negative_integer!(value, name)
        return value if value.is_a?(Integer) && !value.negative?

        raise ConfigurationError, "#{name} must be a non-negative integer"
      end
    end

    private_constant :EffectJournalValidation
  end
end
