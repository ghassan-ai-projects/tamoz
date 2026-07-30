# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module SQLite
    module Wire
      MAX_ID_BYTES = 256
      MAX_REQUEST_ID_BYTES = 128
      MAX_NAMESPACE_PARTS = 128
      DIGEST_VERSION = 1
      BACKEND_TIME_SQL = <<~SQL.lines.map(&:strip).join(" ").freeze
        SELECT (
          CAST(strftime('%s', 'now') AS INTEGER) * 1000 +
          CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER)
        )
      SQL

      module_function

      def identity(value, name:, max_bytes: MAX_ID_BYTES)
        SafeText.normalize(
          value,
          name:,
          max_bytes:,
          error_class: ConfigurationError
        )
      end

      def namespace(value)
        unless value.is_a?(Array) && value.length <= MAX_NAMESPACE_PARTS
          raise ConfigurationError,
                "namespace must contain at most #{MAX_NAMESPACE_PARTS} parts"
        end
        normalized = value.map.with_index do |part, index|
          identity(part, name: "namespace[#{index}]")
        end
        JSON.generate(normalized).freeze
      end

      def decode_namespace(bytes)
        value = JSON.parse(bytes, create_additions: false, max_nesting: 256)
        unless value.is_a?(Array) &&
               JSON.generate(value) == bytes &&
               value.length <= MAX_NAMESPACE_PARTS
          raise CheckpointCorruptionError, "stored namespace is invalid"
        end

        value.map.with_index do |part, index|
          SafeText.normalize(
            part,
            name: "stored namespace[#{index}]",
            max_bytes: MAX_ID_BYTES,
            error_class: CheckpointCorruptionError
          )
        end.freeze
      rescue JSON::ParserError, JSON::NestingError => error
        raise CheckpointCorruptionError.new("stored namespace is invalid"), cause: error
      end

      def digest(bytes, domain:)
        unless bytes.is_a?(String)
          raise ConfigurationError, "digest payload must be a String"
        end

        body = "#{domain}\0v#{DIGEST_VERSION}\0".b
        "sha256:#{Digest::SHA256.hexdigest(body + bytes.b)}".freeze
      end

      def blob(bytes)
        unless bytes.is_a?(String)
          raise ConfigurationError, "SQLite BLOB payload must be a String"
        end

        ::SQLite3::Blob.new(bytes.b)
      end

      def verify_digest!(bytes, expected, domain:)
        actual = digest(bytes, domain:)
        return true if secure_compare(actual, expected)

        raise CheckpointCorruptionError, "#{domain} digest is invalid"
      end

      def secure_compare(left, right)
        return false unless right.is_a?(String) && left.bytesize == right.bytesize

        difference = 0
        left.bytes.zip(right.bytes) do |left_byte, right_byte|
          difference |= left_byte ^ right_byte
        end
        difference.zero?
      end

      private_class_method :secure_compare
    end

    private_constant :Wire
  end
end
