# frozen_string_literal: true

module Tamoz
  module Immutable
    DEFAULT_MAX_DEPTH = 64
    DEFAULT_MAX_COLLECTION_ITEMS = 100_000
    DEFAULT_MAX_STRING_BYTES = 1_048_576

    module_function

    def copy(
      value,
      reject_sensitive: true,
      max_depth: DEFAULT_MAX_DEPTH,
      max_collection_items: DEFAULT_MAX_COLLECTION_ITEMS,
      max_string_bytes: DEFAULT_MAX_STRING_BYTES
    )
      limits = {
        max_depth: positive_integer!(max_depth, :max_depth),
        max_collection_items: positive_integer!(max_collection_items, :max_collection_items),
        max_string_bytes: positive_integer!(max_string_bytes, :max_string_bytes)
      }
      state = {items: 0, active: {}}
      copy_value(value, reject_sensitive:, limits:, state:, depth: 0, path: "$")
    end

    def copy_value(value, reject_sensitive:, limits:, state:, depth:, path:)
      if reject_sensitive && value.is_a?(Secret)
        raise SensitiveValueError, "#{path}: Tamoz::Secret is not permitted"
      end
      raise StateLimitError, "#{path}: nesting exceeds #{limits.fetch(:max_depth)}" if depth > limits.fetch(:max_depth)

      case value
      when NilClass, TrueClass, FalseClass, Integer, Symbol
        value
      when Float
        raise UnsupportedValueError, "#{path}: non-finite floats are unsupported" unless value.finite?

        value
      when String
        copy_string(value, limits:, path:)
      when Array
        copy_container(value, state:, path:) do
          count_items!(value.length, limits:, state:, path:)
          value.each_with_index.map do |entry, index|
            copy_value(
              entry,
              reject_sensitive:,
              limits:,
              state:,
              depth: depth + 1,
              path: "#{path}[#{index}]"
            )
          end.freeze
        end
      when Hash
        copy_container(value, state:, path:) do
          count_items!(value.length, limits:, state:, path:)
          value.each_with_object({}) do |(key, entry), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise UnsupportedValueError, "#{path}: hash key #{key.inspect} must be a string or symbol"
            end

            copied_key = key.is_a?(String) ? copy_string(key, limits:, path: "#{path}.<key>") : key
            result[copied_key] = copy_value(
              entry,
              reject_sensitive:,
              limits:,
              state:,
              depth: depth + 1,
              path: "#{path}.#{key}"
            )
          end.freeze
        end
      else
        raise UnsupportedValueError, "#{path}: unsupported value #{value.class}"
      end
    end
    private_class_method :copy_value

    def copy_container(value, state:, path:)
      object_id = value.object_id
      raise UnsupportedValueError, "#{path}: cyclic containers are unsupported" if state.fetch(:active).key?(object_id)

      state.fetch(:active)[object_id] = true
      yield
    ensure
      state.fetch(:active).delete(object_id)
    end
    private_class_method :copy_container

    def copy_string(value, limits:, path:)
      utf8 = value.encode(Encoding::UTF_8)
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string" unless utf8.valid_encoding?
      if utf8.bytesize > limits.fetch(:max_string_bytes)
        raise StateLimitError, "#{path}: string exceeds #{limits.fetch(:max_string_bytes)} bytes"
      end

      utf8.dup.freeze
    rescue EncodingError => error
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string: #{error.message}"
    end
    private_class_method :copy_string

    def count_items!(count, limits:, state:, path:)
      state[:items] += count
      return if state.fetch(:items) <= limits.fetch(:max_collection_items)

      raise StateLimitError,
            "#{path}: collections exceed #{limits.fetch(:max_collection_items)} total items"
    end
    private_class_method :count_items!

    def positive_integer!(value, name)
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, "#{name} must be a positive integer"
    end
    private_class_method :positive_integer!
  end

  private_constant :Immutable
end
