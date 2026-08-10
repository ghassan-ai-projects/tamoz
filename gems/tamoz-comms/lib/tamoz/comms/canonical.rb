# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Comms
    # Deterministic, domain-separated hashing for channel values (design §6, §9).
    #
    # The canonical encoding sorts hash keys and renders every scalar in a
    # fixed byte form, so the same logical value hashes identically no matter
    # how its keys were inserted. Domains keep distinct contracts from ever
    # colliding (a delivery id can never equal a request id).
    module Canonical
      module_function

      def hexdigest(domain, value)
        ::Digest::SHA256.hexdigest([domain, canonical_bytes(value)].join("\n"))
      end

      def canonical_bytes(value)
        case value
        when Hash then canonical_hash(value)
        when Array then canonical_array(value)
        when String, Symbol, Integer, Float, Time, TrueClass, FalseClass, NilClass
          canonical_scalar(value)
        else
          raise ValidationError, "cannot canonicalize #{value.class}"
        end
      end

      def canonical_hash(value)
        pairs = value.map { |key, entry| [canonical_bytes(key), canonical_bytes(entry)] }
                     .sort_by { |key_bytes, _| key_bytes }
                     .map { |key_bytes, entry_bytes| [key_bytes, entry_bytes].join(':') }
        "{#{pairs.join(',')}}"
      end

      def canonical_array(value)
        "[#{value.map { |entry| canonical_bytes(entry) }.join(',')}]"
      end

      def canonical_scalar(value)
        case value
        when String, Symbol then JSON.generate(value.to_s)
        when Time then canonical_bytes(value.utc.iso8601(6))
        else canonical_literal(value)
        end
      end

      def canonical_literal(value)
        case value
        when Integer, Float then value.to_s
        when TrueClass then 'true'
        when FalseClass then 'false'
        when NilClass then 'null'
        end
      end
    end
  end
end
