# frozen_string_literal: true

module Tamoz
  class StateCodec
    # Turns a state value into the tagged wire tree, enforcing the codec limits on the way.
    class Encoder
      def initialize(codec, encoders)
        @codec = codec
        @encoders = encoders
        @budget = ItemBudget.new(codec.max_collection_items, StateLimitError)
        @active = {}
      end

      def encode(value)
        encode_node(value, depth: 0, path: '$')
      end

      private

      def encode_node(value, depth:, path:)
        raise StateLimitError, "#{path}: nesting exceeds #{@codec.max_depth}" if depth > @codec.max_depth
        raise SensitiveValueError, "#{path}: Tamoz::Secret is not serializable" if value.is_a?(Secret)

        case value
        when Array then encode_array(value, depth:, path:)
        when Hash then encode_hash(value, depth:, path:)
        when NilClass, TrueClass, FalseClass, Integer, Float, String, Symbol then encode_scalar(value, path:)
        else encode_registered(value, depth:, path:)
        end
      end

      def encode_scalar(value, path:)
        case value
        when NilClass then ['nil']
        when TrueClass, FalseClass then ['boolean', value]
        when Integer then ['integer', value]
        when Float then ['float', finite_float(value, path:)]
        when String then ['string', encode_string(value, path:)]
        when Symbol then raise UnsupportedValueError, "#{path}: symbol values are unsupported"
        end
      end

      def finite_float(value, path:)
        return value if value.finite?

        raise UnsupportedValueError, "#{path}: non-finite floats are unsupported"
      end

      def encode_array(value, depth:, path:)
        within_container(value, path:) do
          @budget.spend!(value.length, path:)
          entries = value.each_with_index.map do |entry, index|
            encode_node(entry, depth: depth + 1, path: "#{path}[#{index}]")
          end
          ['array', entries]
        end
      end

      def encode_hash(value, depth:, path:)
        within_container(value, path:) do
          @budget.spend!(value.length, path:)
          normalized = string_keyed(value, path:)
          entries = normalized.keys.sort.map do |key|
            [key, encode_node(normalized.fetch(key), depth: depth + 1, path: "#{path}.#{key}")]
          end
          ['object', entries]
        end
      end

      def string_keyed(value, path:)
        value.each_with_object({}) do |(key, entry), normalized|
          string_key = encode_key(key, path:)
          if normalized.key?(string_key)
            raise UnsupportedValueError, "#{path}: string and symbol keys collide as #{string_key.inspect}"
          end

          normalized[string_key] = entry
        end
      end

      def encode_key(key, path:)
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise UnsupportedValueError, "#{path}: hash keys must be strings or symbols"
        end

        encode_string(key.to_s, path: "#{path}.<key>")
      end

      def encode_registered(value, depth:, path:)
        registration = registration_for(value, path:)
        within_container(value, path:) do
          payload = registration.encoder.call(value)
          ['registered', registration.tag, registration.version,
           encode_node(payload, depth: depth + 1, path: "#{path}.<payload>")]
        rescue Error, ConfigurationError, InvalidUpdateError
          raise
        rescue StandardError => e
          raise InvalidUpdateError.new(
            "codec encoder #{registration.tag}@#{registration.version} failed: #{e.class}"
          ), cause: e
        end
      end

      def registration_for(value, path:)
        registration = @encoders[value.class]
        raise UnsupportedValueError, "#{path}: unsupported value #{value.class}" unless registration
        raise InvalidUpdateError, "#{path}: registered value is mutable" unless registration.immutability.call(value)

        registration
      end

      def within_container(value, path:)
        object_id = value.object_id
        raise UnsupportedValueError, "#{path}: cyclic values are unsupported" if @active.key?(object_id)

        @active[object_id] = true
        yield
      ensure
        @active.delete(object_id) if object_id
      end

      def encode_string(value, path:)
        utf8 = value.encode(Encoding::UTF_8)
        raise UnsupportedValueError, "#{path}: invalid UTF-8 string" unless utf8.valid_encoding?
        if utf8.bytesize > @codec.max_string_bytes
          raise StateLimitError, "#{path}: string exceeds #{@codec.max_string_bytes} bytes"
        end

        utf8
      rescue EncodingError => e
        raise UnsupportedValueError, "#{path}: invalid UTF-8 string: #{e.message}"
      end
    end
  end
end
