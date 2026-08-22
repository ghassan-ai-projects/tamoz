# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Evals
    module CanonicalJSON
      DIGEST_VERSION = 1
      PREFIX = "tamoz-evals".b.freeze

      module_function

      def dump(value)
        JSON.generate(normalize(value))
      rescue JSON::GeneratorError => error
        raise InvalidArtifactError, "value is not canonical JSON: #{error.message}"
      end

      def dump_with_floats(value)
        JSON.generate(normalize(value, 0, allow_floats: true))
      rescue JSON::GeneratorError => error
        raise InvalidArtifactError, "value is not canonical JSON: #{error.message}"
      end

      def content_digest(document, domain:)
        unless document.is_a?(Hash)
          raise InvalidArtifactError, "artifact root must be an object"
        end

        body = document.reject { |key, _value| key == "content_digest" }
        payload = [PREFIX, domain, "v#{DIGEST_VERSION}", dump(body)].join("\0")
        "sha256:#{Digest::SHA256.hexdigest(payload)}"
      end

      def file_digest(path)
        "sha256:#{Digest::SHA256.file(path).hexdigest}"
      end

      def normalize(value, depth = 0, allow_floats: false)
        raise InvalidArtifactError, "artifact nesting exceeds 100" if depth > 100

        case value
        when Hash
          normalize_object(value, depth, allow_floats:)
        when Array
          value.map { |entry| normalize(entry, depth + 1, allow_floats:) }
        when String
          normalize_string(value)
        when Integer, TrueClass, FalseClass, NilClass
          value
        when Float
          normalize_float(value, allow_floats)
        else
          raise InvalidArtifactError, "unsupported canonical JSON value: #{value.class}"
        end
      end

      def normalize_object(value, depth, allow_floats:)
        normalized = {}

        value.each do |key, entry|
          raise InvalidArtifactError, "object keys must be strings" unless key.is_a?(String)

          normalized_key = normalize_string(key)
          if normalized.key?(normalized_key)
            raise InvalidArtifactError, "object keys collide after Unicode normalization"
          end

          normalized[normalized_key] = normalize(entry, depth + 1, allow_floats:)
        end

        normalized.keys.sort.each_with_object({}) do |key, sorted|
          sorted[key] = normalized.fetch(key)
        end
      end
      private_class_method :normalize_object

      def normalize_float(value, allow_floats)
        return value if allow_floats && value.finite?

        raise InvalidArtifactError, "floating-point values are forbidden; use scaled integers"
      end
      private_class_method :normalize_float

      def normalize_string(value)
        utf8 = value.encode(Encoding::UTF_8)
        raise InvalidArtifactError, "invalid UTF-8 string" unless utf8.valid_encoding?

        utf8.unicode_normalize(:nfc)
      rescue EncodingError => error
        raise InvalidArtifactError, "invalid UTF-8 string: #{error.message}"
      end
      private_class_method :normalize_string
    end
  end
end
