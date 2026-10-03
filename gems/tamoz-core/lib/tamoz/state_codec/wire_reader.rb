# frozen_string_literal: true

module Tamoz
  class StateCodec
    # Validates an untrusted wire tree completely, then decodes it into frozen state.
    class WireReader
      SCALAR_CHECKS = {
        'boolean' => ->(value) { [true, false].include?(value) },
        'integer' => ->(value) { value.is_a?(Integer) },
        'float' => ->(value) { value.is_a?(Float) && value.finite? }
      }.freeze

      def initialize(codec, decoders)
        @codec = codec
        @decoders = decoders
        @budget = ItemBudget.new(codec.max_collection_items, CheckpointCorruptionError)
      end

      def read(node)
        validate_node!(node, depth: 0, path: '$')
        decode_node(node, path: '$')
      end

      private

      def validate_node!(node, depth:, path:)
        raise CheckpointCorruptionError, "#{path}: nesting exceeds #{@codec.max_depth}" if depth > @codec.max_depth
        unless node.is_a?(Array) && node.first.is_a?(String)
          raise CheckpointCorruptionError, "#{path}: encoded node must be a tagged array"
        end

        case node.first
        when 'array' then validate_array_node!(node, depth:, path:)
        when 'object' then validate_object_node!(node, depth:, path:)
        when 'registered' then validate_registered_node!(node, depth:, path:)
        else validate_scalar_node!(node, path:)
        end
      end

      def validate_scalar_node!(node, path:)
        case node.first
        when 'nil' then require_shape!(node, 1, path:)
        when 'string' then validate_string_node!(node, path:)
        when *SCALAR_CHECKS.keys then validate_scalar_value!(node, path:)
        else raise CheckpointCorruptionError, "#{path}: unknown encoded node #{node.first.inspect}"
        end
      end

      def validate_string_node!(node, path:)
        require_shape!(node, 2, path:)
        validate_wire_string!(node.fetch(1), path:)
      end

      def validate_scalar_value!(node, path:)
        require_shape!(node, 2, path:)
        return if SCALAR_CHECKS.fetch(node.first).call(node.fetch(1))

        raise CheckpointCorruptionError, "#{path}: invalid #{node.first} node"
      end

      def validate_array_node!(node, depth:, path:)
        collection_payload(node, 'array', path:).each_with_index do |entry, index|
          validate_node!(entry, depth: depth + 1, path: "#{path}[#{index}]")
        end
      end

      def validate_object_node!(node, depth:, path:)
        keys = collection_payload(node, 'object', path:).each_with_index.map do |entry, index|
          validate_object_entry!(entry, index, depth:, path:)
        end
        return if keys == keys.sort && keys.uniq.length == keys.length

        raise CheckpointCorruptionError, "#{path}: object keys must be unique and sorted"
      end

      def collection_payload(node, kind, path:)
        require_shape!(node, 2, path:)
        entries = node.fetch(1)
        raise CheckpointCorruptionError, "#{path}: #{kind} payload must be an array" unless entries.is_a?(Array)

        @budget.spend!(entries.length, path:)
        entries
      end

      def validate_object_entry!(entry, index, depth:, path:)
        unless entry.is_a?(Array) && entry.length == 2
          raise CheckpointCorruptionError, "#{path}[#{index}]: object entry is invalid"
        end

        key = entry.fetch(0)
        validate_wire_string!(key, path: "#{path}[#{index}].<key>")
        validate_node!(entry.fetch(1), depth: depth + 1, path: "#{path}.#{key}")
        key
      end

      def validate_registered_node!(node, depth:, path:)
        require_shape!(node, 4, path:)
        tag, version = node.values_at(1, 2)
        validate_wire_string!(tag, path: "#{path}.<tag>")
        unless TAG_PATTERN.match?(tag) && version.is_a?(Integer) && version.positive?
          raise CheckpointCorruptionError, "#{path}: invalid registered type identity"
        end
        unless @decoders.key?([tag, version])
          raise CheckpointVersionError, "unsupported registered type #{tag}@#{version}"
        end

        validate_node!(node.fetch(3), depth: depth + 1, path: "#{path}.<payload>")
      end

      def decode_node(node, path:)
        case node.first
        when 'nil' then nil
        when 'boolean', 'integer', 'float' then node.fetch(1)
        when 'string' then node.fetch(1).dup.freeze
        when 'array' then decode_array(node, path:)
        when 'object' then decode_object(node, path:)
        when 'registered' then decode_registered(node, path:)
        end
      end

      def decode_array(node, path:)
        node.fetch(1).each_with_index.map do |entry, index|
          decode_node(entry, path: "#{path}[#{index}]")
        end.freeze
      end

      def decode_object(node, path:)
        node.fetch(1).each_with_object({}) do |(key, entry), result|
          result[key.dup.freeze] = decode_node(entry, path: "#{path}.#{key}")
        end.freeze
      end

      def decode_registered(node, path:)
        registration = @decoders.fetch([node.fetch(1), node.fetch(2)])
        value = registration.decoder.call(decode_node(node.fetch(3), path: "#{path}.<payload>"))
        verify_decoded!(registration, value, path:)
        value
      rescue CheckpointCorruptionError
        raise
      rescue StandardError => e
        raise CheckpointCorruptionError.new(
          "codec decoder #{registration.tag}@#{registration.version} failed: #{e.class}"
        ), cause: e
      end

      def verify_decoded!(registration, value, path:)
        unless value.instance_of?(registration.klass)
          raise CheckpointCorruptionError,
                "#{path}: decoder returned #{value.class}, expected #{registration.klass}"
        end
        return if registration.immutability.call(value)

        raise CheckpointCorruptionError, "#{path}: decoder returned a mutable registered value"
      end

      def validate_wire_string!(value, path:)
        unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
          raise CheckpointCorruptionError, "#{path}: invalid UTF-8 string"
        end
        return if value.bytesize <= @codec.max_string_bytes

        raise CheckpointCorruptionError, "#{path}: string exceeds #{@codec.max_string_bytes} bytes"
      end

      def require_shape!(node, length, path:)
        return if node.length == length

        raise CheckpointCorruptionError, "#{path}: invalid #{node.first.inspect} node shape"
      end
    end
  end
end
