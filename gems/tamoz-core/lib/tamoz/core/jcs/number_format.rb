# frozen_string_literal: true

module Tamoz
  module Core
    module JCS
      # Numbers as ECMAScript Number::toString writes them, the form the shared vectors pin.
      module NumberFormat
        module_function

        def exact_double?(integer)
          return true if integer.abs <= MAX_SAFE_INTEGER

          double = integer.to_f
          double.finite? && double.to_i == integer
        end

        def integer_to_s(value)
          raise Error, "integer #{value} is not exactly representable as a double" unless exact_double?(value)

          # Integers beyond MAX_SAFE_INTEGER that survive a double round-trip
          # must serialize with ES shortest-round-trip semantics, not their exact
          # decimal (Go agrees with ES: 2**60 -> "1152921504606847000").
          return float_to_s(value.to_f) if value.abs > MAX_SAFE_INTEGER

          value.to_s
        end

        def float_to_s(value)
          raise Error, 'NaN is not representable' if value.nan?
          raise Error, 'infinite is not representable' if value.infinite?
          raise Error, 'negative zero is not representable' if value.zero? && (1.0 / value).negative?

          digits, point = shortest_digits(value)
          body = format_number(digits, point)
          value.negative? ? "-#{body}" : body
        end

        # Ruby's Float#to_s is shortest-round-trip but keeps shapes ES would
        # drop ("5.0e-324" -> digits "5", "1.0" -> digits "1"). Extract the
        # shortest digits (trailing zeros removed only when they still
        # round-trip), then re-emit under the ES exponent-threshold rules.
        def shortest_digits(value)
          return ['0', 1] if value.zero?

          digits, point = decimal_digits(value)
          [trim_trailing_zeros(digits, point, value), point]
        end

        def decimal_digits(value)
          mantissa, exponent = value.to_s.delete_prefix('-').split(/[eE]/, 2)
          integer_part, fraction = mantissa.split('.', 2)
          digits = integer_part + (fraction || '')
          stripped = digits.sub(/\A0+/, '')
          point = integer_part.length + exponent.to_i - (digits.length - stripped.length)
          [stripped.empty? ? '0' : stripped, point]
        end

        def trim_trailing_zeros(digits, point, value)
          while digits.length > 1 && digits.end_with?('0')
            trimmed = digits[0...-1]
            break unless round_trips?(trimmed, point, value)

            digits = trimmed
          end
          digits
        end

        def round_trips?(digits, point, value)
          plain_decimal(digits, point).to_f.to_r == value.abs.to_r
        end

        def format_number(digits, point)
          return plain_decimal(digits, point) if point.between?(-5, 21)

          exponential_decimal(digits, point)
        end

        def plain_decimal(digits, point)
          if digits.length <= point then digits + ('0' * (point - digits.length))
          elsif point.positive? then "#{digits[0...point]}.#{digits[point..]}"
          else "0.#{'0' * -point}#{digits}"
          end
        end

        def exponential_decimal(digits, point)
          exponent = point - 1
          fraction = digits.length > 1 ? ".#{digits[1..]}" : ''
          sign = exponent.negative? ? '-' : '+'
          "#{digits[0]}#{fraction}e#{sign}#{exponent.abs}"
        end
      end
    end
  end
end
