# frozen_string_literal: true

module Tamoz
  module Graph
    # Validates graph identities and canonical checkpoint values.
    class CheckpointValues
      STATUSES = %w[running paused failed completed].freeze
      attr_reader :state_codec

      def initialize(definition:, state_codec:)
        @state_codec = state_codec
        @channels_by_name = definition.channels.to_h { |name, _channel| [name.to_s.freeze, name] }.freeze
        @nodes_by_name = definition.nodes.to_h { |name, _node| [name.to_s.freeze, name] }.freeze
        freeze
      end

      def parse_canonical_json(bytes, name)
        raise CheckpointCorruptionError, "#{name} must be encoded bytes" unless bytes.is_a?(String)

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        raise CheckpointCorruptionError, "#{name} is not valid UTF-8" unless text.valid_encoding?

        wire = JSON.parse(text, create_additions: false, max_nesting: 512)
        raise CheckpointCorruptionError, "#{name} is not canonical JSON" unless JSON.generate(wire) == text

        wire
      rescue JSON::ParserError, JSON::NestingError => e
        raise CheckpointCorruptionError.new("#{name} is invalid JSON"), cause: e
      end

      def decode_state(bytes, strict: true)
        raw = load_value(bytes)
        raise CheckpointCorruptionError, 'checkpoint state must decode to a Hash' unless raw.is_a?(Hash)
        return raw.freeze if !strict && @channels_by_name.keys.sort != raw.keys.sort

        if raw.keys.sort != @channels_by_name.keys.sort
          raise CheckpointCorruptionError,
                'checkpoint state channels do not match the compiled graph'
        end

        raw.to_h do |name, value|
          [channel!(name, 'state channel'), value]
        end.freeze
      end

      def decode_update(bytes)
        raw = load_value(bytes)
        raise CheckpointCorruptionError, 'pending update must decode to a Hash' unless raw.is_a?(Hash)

        raw.to_h do |name, value|
          [channel!(name, 'update channel'), value]
        end.freeze
      end

      def dump_value(value)
        state_codec.dump(value).dup.freeze
      rescue CheckpointVersionError, CheckpointCorruptionError, InvalidUpdateError
        raise
      rescue StandardError => e
        raise CheckpointCorruptionError.new(
          'checkpoint value could not be encoded'
        ), cause: e
      end

      def verify_canonical_value_bytes(bytes)
        load_value(bytes)
        bytes.dup.freeze
      end

      def load_value(bytes)
        raise CheckpointCorruptionError, 'encoded checkpoint value must be a String' unless bytes.is_a?(String)

        value = state_codec.load(bytes)
        # Canonicality is a BYTE property: an adapter may hand back the stored
        # payload as ASCII-8BIT (SQLite BLOB), which never compares equal to a
        # UTF-8 dump unless both are ASCII-only.
        unless state_codec.dump(value).b == bytes.b
          raise CheckpointCorruptionError,
                'checkpoint contains a non-canonical encoded value'
        end

        value
      rescue CheckpointVersionError, CheckpointCorruptionError
        raise
      rescue InvalidUpdateError => e
        raise CheckpointCorruptionError.new(
          'checkpoint value cannot be revived'
        ), cause: e
      end

      def node!(value, name)
        text = bounded_string!(value, name)
        @nodes_by_name.fetch(text) do
          raise CheckpointCorruptionError, "#{name} is not declared by the graph"
        end
      end

      def channel!(value, name)
        text = bounded_string!(value, name)
        @channels_by_name.fetch(text) do
          raise CheckpointCorruptionError, "#{name} is not declared by the graph"
        end
      end

      def status!(value)
        unless value.is_a?(String) && STATUSES.include?(value)
          raise CheckpointCorruptionError, 'checkpoint status is invalid'
        end

        value.to_sym
      end

      def bounded_string!(value, name)
        SafeText.normalize(
          value,
          name:,
          max_bytes: 256,
          error_class: CheckpointCorruptionError
        )
      end

      def optional_string!(value, name)
        value.nil? ? nil : bounded_string!(value, name)
      end

      def string_array!(value, name)
        require_array!(value, nil, name)
        raise CheckpointCorruptionError, "#{name} must not be empty" if value.empty?

        value.map.with_index do |entry, index|
          bounded_string!(entry, "#{name}[#{index}]")
        end.freeze
      end

      def enforce_strictly_ascending!(current, previous, message)
        raise CheckpointCorruptionError, message if previous && current <= previous

        current
      end

      def require_array!(value, size, name)
        return if value.is_a?(Array) && (size.nil? || value.length == size)

        expectation = size ? " with #{size} items" : ''
        raise CheckpointCorruptionError, "#{name} must be an Array#{expectation}"
      end

      def positive_integer!(value, name)
        return value if value.is_a?(Integer) && value.positive?

        raise CheckpointCorruptionError, "#{name} must be a positive integer"
      end

      def non_negative_integer!(value, name)
        return value if value.is_a?(Integer) && !value.negative?

        raise CheckpointCorruptionError,
              "#{name} must be a non-negative integer"
      end
    end

    private_constant :CheckpointValues
  end
end
