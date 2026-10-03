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
        validate_identity!(version, klass)
        validate_callables!(encoder:, decoder:, immutability:)
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

      private

      def validate_identity!(version, klass)
        raise ConfigurationError, "codec tag must match #{TAG_PATTERN.inspect}" unless TAG_PATTERN.match?(@tag)
        unless version.is_a?(Integer) && version.positive?
          raise ConfigurationError, "codec version must be a positive integer"
        end
        raise ConfigurationError, "codec class must be a Class" unless klass.is_a?(Class)
        return unless BUILT_IN_CLASSES.include?(klass) || klass <= Secret

        raise ConfigurationError, "codec class #{klass} is reserved by tamoz-core"
      end

      def validate_callables!(callables)
        { encoder: "codec encoder", decoder: "codec decoder",
          immutability: "codec immutability predicate" }.each do |name, label|
          raise ConfigurationError, "#{label} must respond to call" unless callables.fetch(name).respond_to?(:call)
        end
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
      assign_limits(max_bytes:, max_depth:, max_collection_items:, max_string_bytes:)
      @registrations = registrations.map { |registration| coerce_registration(registration) }.freeze
      validate_registrations!
      @encoders = @registrations.select(&:encode?).to_h { |registration| [registration.klass, registration] }.freeze
      @decoders = @registrations.to_h { |registration| [[registration.tag, registration.version], registration] }.freeze
      freeze
    end

    def add_registration(**attributes)
      self.class.new(
        registrations: [*@registrations, Registration.new(**attributes)],
        max_bytes:,
        max_depth:,
        max_collection_items:,
        max_string_bytes:
      )
    end

    def dump(value)
      bytes = JSON.generate([FORMAT, FORMAT_VERSION, Encoder.new(self, @encoders).encode(value)])
      raise StateLimitError, "encoded state exceeds #{max_bytes} bytes" if bytes.bytesize > max_bytes

      bytes
    rescue JSON::GeneratorError => error
      raise UnsupportedValueError, "state cannot be encoded as JSON: #{error.message}"
    end

    def load(bytes)
      wire = JSON.parse(validate_input_bytes(bytes), create_additions: false, max_nesting: (max_depth * 3) + 16)
      validate_envelope!(wire)
      WireReader.new(self, @decoders).read(wire.fetch(2))
    rescue CheckpointVersionError, CheckpointCorruptionError
      raise
    rescue JSON::ParserError, JSON::NestingError => error
      raise CheckpointCorruptionError.new("invalid state JSON: #{error.message}"), cause: error
    end

    def normalize(value)
      load(dump(value))
    end

    private

    def assign_limits(limits)
      @max_bytes = bounded_integer!(limits.fetch(:max_bytes), :max_bytes, MAX_BYTES)
      @max_depth = bounded_integer!(limits.fetch(:max_depth), :max_depth, MAX_DEPTH)
      @max_collection_items = bounded_integer!(
        limits.fetch(:max_collection_items), :max_collection_items, MAX_COLLECTION_ITEMS
      )
      @max_string_bytes = bounded_integer!(limits.fetch(:max_string_bytes), :max_string_bytes, MAX_STRING_BYTES)
    end

    def validate_envelope!(wire)
      unless wire.is_a?(Array) && wire.length == 3 && wire.first == FORMAT
        raise CheckpointCorruptionError, "state envelope is invalid"
      end
      return if wire.fetch(1) == FORMAT_VERSION

      raise CheckpointVersionError, "unsupported state format version #{wire.fetch(1).inspect}"
    end

    def validate_input_bytes(bytes)
      raise CheckpointCorruptionError, "state input must be a String" unless bytes.is_a?(String)
      raise CheckpointCorruptionError, "state input exceeds #{max_bytes} bytes" if bytes.bytesize > max_bytes

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise CheckpointCorruptionError, "state input is not valid UTF-8" unless text.valid_encoding?

      text
    end

    def validate_registrations!
      if @registrations.length > MAX_REGISTRATIONS
        raise ConfigurationError, "at most #{MAX_REGISTRATIONS} codec registrations are allowed"
      end

      reject_duplicate_decoders!
      reject_duplicate_encoders!
    end

    def reject_duplicate_decoders!
      duplicates = duplicated(@registrations) { |registration| [registration.tag, registration.version] }
      return if duplicates.empty?

      raise ConfigurationError, "duplicate codec tag/version: #{duplicates.sort.inspect}"
    end

    def reject_duplicate_encoders!
      duplicates = duplicated(@registrations.select(&:encode?), &:klass)
      return if duplicates.empty?

      raise ConfigurationError, "multiple active encoders for #{duplicates.map(&:name).sort.inspect}"
    end

    def duplicated(registrations, &identity)
      registrations.group_by(&identity).select { |_identity, entries| entries.length > 1 }.keys
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

    private_constant :BUILT_IN_CLASSES, :Encoder, :WireReader, :ItemBudget
  end
end
