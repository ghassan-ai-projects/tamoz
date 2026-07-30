# frozen_string_literal: true

require "json"

module Tamoz
  class StateCodec
    FORMAT = "tamoz.state"
    FORMAT_VERSION = 1
    TAG_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,127}\z/
    DEFAULT_MAX_BYTES = 4 * 1024 * 1024
    DEFAULT_MAX_DEPTH = 64
    DEFAULT_MAX_COLLECTION_ITEMS = 100_000
    DEFAULT_MAX_STRING_BYTES = 1_048_576
    MAX_BYTES = 64 * 1024 * 1024
    MAX_DEPTH = 256
    MAX_COLLECTION_ITEMS = 1_000_000
    MAX_STRING_BYTES = 16 * 1024 * 1024
    MAX_REGISTRATIONS = 256
    BUILT_IN_CLASSES = [
      NilClass, TrueClass, FalseClass, Integer, Float, String, Symbol, Array, Hash
    ].freeze

    class Registration
      attr_reader :tag, :version, :klass, :encoder, :decoder, :immutability

      def initialize(
        tag:,
        version:,
        klass:,
        encoder:,
        decoder:,
        immutability:,
        encode: true
      )
        @tag = String(tag).dup.freeze
        unless TAG_PATTERN.match?(@tag)
          raise ConfigurationError, "codec tag must match #{TAG_PATTERN.inspect}"
        end
        unless version.is_a?(Integer) && version.positive?
          raise ConfigurationError, "codec version must be a positive integer"
        end
        raise ConfigurationError, "codec class must be a Class" unless klass.is_a?(Class)
        if BUILT_IN_CLASSES.include?(klass) || klass <= Secret
          raise ConfigurationError, "codec class #{klass} is reserved by tamoz-core"
        end
        raise ConfigurationError, "codec encoder must respond to call" unless encoder.respond_to?(:call)
        raise ConfigurationError, "codec decoder must respond to call" unless decoder.respond_to?(:call)
        unless immutability.respond_to?(:call)
          raise ConfigurationError, "codec immutability predicate must respond to call"
        end

        @version = version
        @klass = klass
        @encoder = encoder
        @decoder = decoder
        @immutability = immutability
        @encode = !!encode
        freeze
      end

      def encode?
        @encode
      end
    end

    attr_reader :max_bytes, :max_depth, :max_collection_items, :max_string_bytes

    def initialize(
      registrations: [],
      max_bytes: DEFAULT_MAX_BYTES,
      max_depth: DEFAULT_MAX_DEPTH,
      max_collection_items: DEFAULT_MAX_COLLECTION_ITEMS,
      max_string_bytes: DEFAULT_MAX_STRING_BYTES
    )
      @max_bytes = bounded_integer!(max_bytes, :max_bytes, MAX_BYTES)
      @max_depth = bounded_integer!(max_depth, :max_depth, MAX_DEPTH)
      @max_collection_items = bounded_integer!(
        max_collection_items,
        :max_collection_items,
        MAX_COLLECTION_ITEMS
      )
      @max_string_bytes = bounded_integer!(
        max_string_bytes,
        :max_string_bytes,
        MAX_STRING_BYTES
      )
      @registrations = registrations.map { |registration| coerce_registration(registration) }.freeze
      validate_registrations!
      @encoders = @registrations.select(&:encode?).to_h { |registration| [registration.klass, registration] }.freeze
      @decoders = @registrations.to_h do |registration|
        [[registration.tag, registration.version], registration]
      end.freeze
      freeze
    end

    def with_registration(**attributes)
      self.class.new(
        registrations: [*@registrations, Registration.new(**attributes)],
        max_bytes:,
        max_depth:,
        max_collection_items:,
        max_string_bytes:
      )
    end

    def dump(value)
      state = {items: 0, active: {}}
      encoded = encode_node(value, state:, depth: 0, path: "$")
      bytes = JSON.generate([FORMAT, FORMAT_VERSION, encoded])
      if bytes.bytesize > max_bytes
        raise StateLimitError, "encoded state exceeds #{max_bytes} bytes"
      end

      bytes
    rescue JSON::GeneratorError => error
      raise UnsupportedValueError, "state cannot be encoded as JSON: #{error.message}"
    end

    def load(bytes)
      text = validate_input_bytes(bytes)
      wire = JSON.parse(
        text,
        create_additions: false,
        max_nesting: (max_depth * 3) + 16
      )
      validate_envelope!(wire)
      state = {items: 0}
      validate_node!(wire.fetch(2), state:, depth: 0, path: "$")
      decode_node(wire.fetch(2), path: "$")
    rescue CheckpointVersionError, CheckpointCorruptionError
      raise
    rescue JSON::ParserError, JSON::NestingError => error
      raise CheckpointCorruptionError.new("invalid state JSON: #{error.message}"), cause: error
    end

    def normalize(value)
      load(dump(value))
    end

    private

    def encode_node(value, state:, depth:, path:)
      raise StateLimitError, "#{path}: nesting exceeds #{max_depth}" if depth > max_depth
      raise SensitiveValueError, "#{path}: Tamoz::Secret is not serializable" if value.is_a?(Secret)

      case value
      when NilClass
        ["nil"]
      when TrueClass, FalseClass
        ["boolean", value]
      when Integer
        ["integer", value]
      when Float
        raise UnsupportedValueError, "#{path}: non-finite floats are unsupported" unless value.finite?

        ["float", value]
      when String
        ["string", encode_string(value, path:)]
      when Symbol
        raise UnsupportedValueError, "#{path}: symbol values are unsupported"
      when Array
        encode_container(value, state:, path:) do
          count_items!(value.length, state:, path:)
          [
            "array",
            value.each_with_index.map do |entry, index|
              encode_node(entry, state:, depth: depth + 1, path: "#{path}[#{index}]")
            end
          ]
        end
      when Hash
        encode_hash(value, state:, depth:, path:)
      else
        encode_registered(value, state:, depth:, path:)
      end
    end

    def encode_hash(value, state:, depth:, path:)
      encode_container(value, state:, path:) do
        count_items!(value.length, state:, path:)
        normalized = {}
        value.each do |key, entry|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise UnsupportedValueError, "#{path}: hash keys must be strings or symbols"
          end

          string_key = encode_string(key.to_s, path: "#{path}.<key>")
          if normalized.key?(string_key)
            raise UnsupportedValueError,
                  "#{path}: string and symbol keys collide as #{string_key.inspect}"
          end
          normalized[string_key] = entry
        end

        entries = normalized.keys.sort.map do |key|
          [key, encode_node(normalized.fetch(key), state:, depth: depth + 1, path: "#{path}.#{key}")]
        end
        ["object", entries]
      end
    end

    def encode_registered(value, state:, depth:, path:)
      registration = @encoders[value.class]
      unless registration
        raise UnsupportedValueError, "#{path}: unsupported value #{value.class}"
      end
      unless registration.immutability.call(value)
        raise InvalidUpdateError, "#{path}: registered value is mutable"
      end

      encode_container(value, state:, path:) do
        payload = registration.encoder.call(value)
        [
          "registered",
          registration.tag,
          registration.version,
          encode_node(payload, state:, depth: depth + 1, path: "#{path}.<payload>")
        ]
      rescue Error, ConfigurationError, InvalidUpdateError
        raise
      rescue StandardError => error
        raise InvalidUpdateError.new(
          "codec encoder #{registration.tag}@#{registration.version} failed: #{error.class}"
        ), cause: error
      end
    end

    def encode_container(value, state:, path:)
      object_id = value.object_id
      if state.fetch(:active).key?(object_id)
        raise UnsupportedValueError, "#{path}: cyclic values are unsupported"
      end

      state.fetch(:active)[object_id] = true
      yield
    ensure
      state.fetch(:active).delete(object_id) if object_id
    end

    def validate_envelope!(wire)
      unless wire.is_a?(Array) && wire.length == 3 && wire.first == FORMAT
        raise CheckpointCorruptionError, "state envelope is invalid"
      end
      unless wire.fetch(1) == FORMAT_VERSION
        raise CheckpointVersionError, "unsupported state format version #{wire.fetch(1).inspect}"
      end
    end

    def validate_node!(node, state:, depth:, path:)
      raise CheckpointCorruptionError, "#{path}: nesting exceeds #{max_depth}" if depth > max_depth
      unless node.is_a?(Array) && node.first.is_a?(String)
        raise CheckpointCorruptionError, "#{path}: encoded node must be a tagged array"
      end

      case node.first
      when "nil"
        require_shape!(node, 1, path:)
      when "boolean"
        require_shape!(node, 2, path:)
        unless node.fetch(1) == true || node.fetch(1) == false
          raise CheckpointCorruptionError, "#{path}: invalid boolean node"
        end
      when "integer"
        require_shape!(node, 2, path:)
        raise CheckpointCorruptionError, "#{path}: invalid integer node" unless node.fetch(1).is_a?(Integer)
      when "float"
        require_shape!(node, 2, path:)
        value = node.fetch(1)
        unless value.is_a?(Float) && value.finite?
          raise CheckpointCorruptionError, "#{path}: invalid float node"
        end
      when "string"
        require_shape!(node, 2, path:)
        validate_wire_string!(node.fetch(1), path:)
      when "array"
        validate_array_node!(node, state:, depth:, path:)
      when "object"
        validate_object_node!(node, state:, depth:, path:)
      when "registered"
        validate_registered_node!(node, state:, depth:, path:)
      else
        raise CheckpointCorruptionError, "#{path}: unknown encoded node #{node.first.inspect}"
      end
    end

    def validate_array_node!(node, state:, depth:, path:)
      require_shape!(node, 2, path:)
      entries = node.fetch(1)
      raise CheckpointCorruptionError, "#{path}: array payload must be an array" unless entries.is_a?(Array)

      count_items_for_load!(entries.length, state:, path:)
      entries.each_with_index do |entry, index|
        validate_node!(entry, state:, depth: depth + 1, path: "#{path}[#{index}]")
      end
    end

    def validate_object_node!(node, state:, depth:, path:)
      require_shape!(node, 2, path:)
      entries = node.fetch(1)
      raise CheckpointCorruptionError, "#{path}: object payload must be an array" unless entries.is_a?(Array)

      count_items_for_load!(entries.length, state:, path:)
      keys = entries.each_with_index.map do |entry, index|
        unless entry.is_a?(Array) && entry.length == 2
          raise CheckpointCorruptionError, "#{path}[#{index}]: object entry is invalid"
        end

        key = entry.fetch(0)
        validate_wire_string!(key, path: "#{path}[#{index}].<key>")
        validate_node!(entry.fetch(1), state:, depth: depth + 1, path: "#{path}.#{key}")
        key
      end
      unless keys == keys.sort && keys.uniq.length == keys.length
        raise CheckpointCorruptionError, "#{path}: object keys must be unique and sorted"
      end
    end

    def validate_registered_node!(node, state:, depth:, path:)
      require_shape!(node, 4, path:)
      tag = node.fetch(1)
      version = node.fetch(2)
      validate_wire_string!(tag, path: "#{path}.<tag>")
      unless TAG_PATTERN.match?(tag) && version.is_a?(Integer) && version.positive?
        raise CheckpointCorruptionError, "#{path}: invalid registered type identity"
      end
      unless @decoders.key?([tag, version])
        raise CheckpointVersionError, "unsupported registered type #{tag}@#{version}"
      end

      validate_node!(node.fetch(3), state:, depth: depth + 1, path: "#{path}.<payload>")
    end

    def decode_node(node, path:)
      case node.first
      when "nil" then nil
      when "boolean", "integer", "float" then node.fetch(1)
      when "string" then node.fetch(1).dup.freeze
      when "array"
        node.fetch(1).each_with_index.map do |entry, index|
          decode_node(entry, path: "#{path}[#{index}]")
        end.freeze
      when "object"
        node.fetch(1).each_with_object({}) do |(key, entry), result|
          result[key.dup.freeze] = decode_node(entry, path: "#{path}.#{key}")
        end.freeze
      when "registered"
        decode_registered(node, path:)
      end
    end

    def decode_registered(node, path:)
      registration = @decoders.fetch([node.fetch(1), node.fetch(2)])
      payload = decode_node(node.fetch(3), path: "#{path}.<payload>")
      value = registration.decoder.call(payload)
      unless value.class.equal?(registration.klass)
        raise CheckpointCorruptionError,
              "#{path}: decoder returned #{value.class}, expected #{registration.klass}"
      end
      unless registration.immutability.call(value)
        raise CheckpointCorruptionError, "#{path}: decoder returned a mutable registered value"
      end

      value
    rescue CheckpointCorruptionError
      raise
    rescue StandardError => error
      raise CheckpointCorruptionError.new(
        "codec decoder #{registration.tag}@#{registration.version} failed: #{error.class}"
      ), cause: error
    end

    def validate_input_bytes(bytes)
      unless bytes.is_a?(String)
        raise CheckpointCorruptionError, "state input must be a String"
      end
      if bytes.bytesize > max_bytes
        raise CheckpointCorruptionError, "state input exceeds #{max_bytes} bytes"
      end

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise CheckpointCorruptionError, "state input is not valid UTF-8" unless text.valid_encoding?

      text
    end

    def encode_string(value, path:)
      utf8 = value.encode(Encoding::UTF_8)
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string" unless utf8.valid_encoding?
      if utf8.bytesize > max_string_bytes
        raise StateLimitError, "#{path}: string exceeds #{max_string_bytes} bytes"
      end

      utf8
    rescue EncodingError => error
      raise UnsupportedValueError, "#{path}: invalid UTF-8 string: #{error.message}"
    end

    def validate_wire_string!(value, path:)
      unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
        raise CheckpointCorruptionError, "#{path}: invalid UTF-8 string"
      end
      if value.bytesize > max_string_bytes
        raise CheckpointCorruptionError, "#{path}: string exceeds #{max_string_bytes} bytes"
      end
    end

    def require_shape!(node, length, path:)
      return if node.length == length

      raise CheckpointCorruptionError, "#{path}: invalid #{node.first.inspect} node shape"
    end

    def count_items!(count, state:, path:)
      state[:items] += count
      return if state.fetch(:items) <= max_collection_items

      raise StateLimitError, "#{path}: collections exceed #{max_collection_items} total items"
    end

    def count_items_for_load!(count, state:, path:)
      state[:items] += count
      return if state.fetch(:items) <= max_collection_items

      raise CheckpointCorruptionError,
            "#{path}: collections exceed #{max_collection_items} total items"
    end

    def validate_registrations!
      if @registrations.length > MAX_REGISTRATIONS
        raise ConfigurationError, "at most #{MAX_REGISTRATIONS} codec registrations are allowed"
      end

      duplicate_decoders = @registrations
                           .group_by { |registration| [registration.tag, registration.version] }
                           .select { |_identity, entries| entries.length > 1 }
      unless duplicate_decoders.empty?
        raise ConfigurationError,
              "duplicate codec tag/version: #{duplicate_decoders.keys.sort.inspect}"
      end

      duplicate_encoders = @registrations
                           .select(&:encode?)
                           .group_by(&:klass)
                           .select { |_klass, entries| entries.length > 1 }
      unless duplicate_encoders.empty?
        raise ConfigurationError,
              "multiple active encoders for #{duplicate_encoders.keys.map(&:name).sort.inspect}"
      end
    end

    def coerce_registration(registration)
      return registration if registration.is_a?(Registration)
      return Registration.new(**registration) if registration.is_a?(Hash)

      raise ConfigurationError, "registrations must be Registration values or keyword hashes"
    end

    def bounded_integer!(value, name, maximum)
      return value if value.is_a?(Integer) && value.positive? && value <= maximum

      raise ConfigurationError, "#{name} must be between 1 and #{maximum}"
    end

    private_constant :BUILT_IN_CLASSES
  end
end
