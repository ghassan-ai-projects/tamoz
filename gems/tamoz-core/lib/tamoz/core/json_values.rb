# frozen_string_literal: true

module Tamoz
  module Core
    # Deep frozen and deep mutable copies of JSON-shaped values.
    module JsonValues
      module_function

      # Deep freezer for JSON-shaped values (the plan/session-records freezer, homed
      # in core so the skills compiler and the durable records share one
      # implementation). Scalars are returned as-is, containers are rebuilt with
      # frozen keys/values, and anything that cannot cross a durable boundary raises.
      def deep_freeze(value)
        case value
        when Hash
          value.to_h { |key, entry| [String(key).dup.freeze, deep_freeze(entry)] }.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        when String
          value.dup.freeze
        when NilClass, TrueClass, FalseClass, Numeric
          value
        else
          raise Tamoz::Error, "unsupported plan argument #{value.class}"
        end
      end

      # Deep MUTABLE copy for JSON-shaped values — the counterpart of deep_freeze
      # for the paths that must go on mutating the result. Keys and strings are
      # duplicated so the copy shares no mutable state with the original, and key
      # types are preserved (unlike deep_freeze, which stringifies and freezes).
      # Homed here so the circuit record and the stream decision builder share one
      # implementation instead of hand-rolling a spelling each.
      def deep_dup(value)
        case value
        when Hash then value.to_h { |key, entry| [deep_dup(key), deep_dup(entry)] }
        when Array then value.map { |entry| deep_dup(entry) }
        when String then value.dup
        else value
        end
      end
    end
    private_constant :JsonValues
  end
end
