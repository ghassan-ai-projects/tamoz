# frozen_string_literal: true

module Tamoz
  module Evals
    # Frozen-ness and shape checks shared by the SQLite harness recorders and
    # controls. `module_function` exposes each both as a module method and, on
    # `include`, as a private instance method, so the harness classes keep their
    # bare call sites (`deeply_frozen?(x)`) while the single definition lives
    # here beside DeepFreeze. All shape failures raise Tamoz::Evals::ExecutionError.
    module ShapeValidation
      module_function

      def deeply_frozen?(value)
        return false unless value.frozen?

        case value
        when Hash
          value.all? { |key, entry| deeply_frozen?(key) && deeply_frozen?(entry) }
        when Array
          value.all? { |entry| deeply_frozen?(entry) }
        else
          true
        end
      end

      def validate_exact_hash(value, keys, name:)
        unless value.is_a?(Hash) &&
               value.length == keys.length &&
               keys.all? { |key| value.key?(key) }
          raise ExecutionError, "#{name} shape is invalid"
        end

        value
      end

      def bounded_utf8(value, name:, maximum:)
        unless value.is_a?(String) &&
               value.valid_encoding? &&
               !value.empty? &&
               value.bytesize <= maximum
          raise ExecutionError, "#{name} is invalid"
        end

        value.dup.freeze
      end
    end
  end
end
