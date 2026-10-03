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
      walk = {reject_sensitive:, limits:, items: 0, active: {}}
      copy_value(value, walk, depth: 0, path: "$")
    end

    def copy_value(value, walk, depth:, path:)
      guard_value!(value, walk, depth:, path:)
      case value
      when NilClass, TrueClass, FalseClass, Integer, Symbol then value
      when Float then finite_float(value, path:)
      when String then copy_string(value, walk, path:)
      when Array then copy_array(value, walk, depth:, path:)
      when Hash then copy_hash(value, walk, depth:, path:)
      else raise UnsupportedValueError, "#{path}: unsupported value #{value.class}"
      end
    end
    private_class_method :copy_value

    def guard_value!(value, walk, depth:, path:)
      if walk.fetch(:reject_sensitive) && value.is_a?(Secret)
        raise SensitiveValueError, "#{path}: Tamoz::Secret is not permitted"
      end

      max_depth = walk.fetch(:limits).fetch(:max_depth)
      raise StateLimitError, "#{path}: nesting exceeds #{max_depth}" if depth > max_depth
    end
    private_class_method :guard_value!

    def finite_float(value, path:)
      return value if value.finite?

      raise UnsupportedValueError, "#{path}: non-finite floats are unsupported"
    end
    private_class_method :finite_float

    def copy_array(value, walk, depth:, path:)
      copy_container(value, walk, path:) do
        value.each_with_index.map do |entry, index|
          copy_value(entry, walk, depth: depth + 1, path: "#{path}[#{index}]")
        end.freeze
      end
    end
    private_class_method :copy_array

    def copy_hash(value, walk, depth:, path:)
      copy_container(value, walk, path:) do
        value.each_with_object({}) do |(key, entry), result|
          result[copy_key(key, walk, path:)] = copy_value(entry, walk, depth: depth + 1, path: "#{path}.#{key}")
        end.freeze
      end
    end
    private_class_method :copy_hash

    def copy_key(key, walk, path:)
      return copy_string(key, walk, path: "#{path}.<key>") if key.is_a?(String)
      return key if key.is_a?(Symbol)

      raise UnsupportedValueError, "#{path}: hash key #{key.inspect} must be a string or symbol"
    end
    private_class_method :copy_key

    def copy_container(value, walk, path:)
      object_id = value.object_id
      raise UnsupportedValueError, "#{path}: cyclic containers are unsupported" if walk.fetch(:active).key?(object_id)

      walk.fetch(:active)[object_id] = true
      count_items!(value.length, walk, path:)
      yield
    ensure
      walk.fetch(:active).delete(object_id)
    end
    private_class_method :copy_container

    def copy_string(value, walk, path:)
      max_bytes = walk.fetch(:limits).fetch(:max_string_bytes)
      utf8 = value.encode(Encoding::UTF_8)
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string" unless utf8.valid_encoding?
      raise StateLimitError, "#{path}: string exceeds #{max_bytes} bytes" if utf8.bytesize > max_bytes

      utf8.dup.freeze
    rescue EncodingError => error
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string: #{error.message}"
    end
    private_class_method :copy_string

    def count_items!(count, walk, path:)
      walk[:items] += count
      max_items = walk.fetch(:limits).fetch(:max_collection_items)
      return if walk.fetch(:items) <= max_items

      raise StateLimitError, "#{path}: collections exceed #{max_items} total items"
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
