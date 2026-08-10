# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Observability
    class ContentPolicy
      CLASSES = %i[
        system_instructions input_messages output_messages tool_arguments tool_results
        plan_text review_text error_detail
      ].freeze
      CLASSIFICATION_RANKS = { public: 0, internal: 1, confidential: 2, restricted: 3 }.freeze
      DEFAULT_MAX_BYTES = 4_096

      attr_reader :name, :max_classification, :limits, :digest

      def initialize(name: 'none', max_classification: :internal, **options)
        @name = String(name).freeze
        @max_classification = normalize_classification(max_classification)
        @limits = CLASSES.to_h do |content_class|
          [content_class, normalize_option(options.fetch(content_class, false), content_class)]
        end.freeze
        refuse_restricted_capture!
        @digest = "sha256:#{Digest::SHA256.hexdigest(canonical_document)}".freeze
        freeze
      end

      def capture?(content_class)
        limits.fetch(content_class.to_sym).fetch(:enabled)
      end

      def max_bytes(content_class)
        limits.fetch(content_class.to_sym).fetch(:max_bytes)
      end

      def describe(content_class, value)
        content_class = content_class.to_sym
        raise ValidationError, "unknown content class #{content_class}" unless CLASSES.include?(content_class)

        bytes = canonical_bytes(value)
        digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
        result = {"#{content_class}_digest" => digest, "#{content_class}_bytes" => bytes.bytesize}
        return result unless capture?(content_class)

        limit = max_bytes(content_class)
        result[content_class.to_s] = safe_truncate(bytes, limit)
        result["#{content_class}_truncated"] = true if bytes.bytesize > limit
        result
      end

      def apply(content)
        return {policy_digest: digest, content: {}} if content.nil?

        unless content.is_a?(Hash)
          raise ValidationError, 'content must be a Hash keyed by content class'
        end

        content.each_with_object({policy_digest: digest, content: {}}) do |(key, value), result|
          details = describe(key, value)
          result[:content].merge!(details)
        end
      end

      def to_h
        {
          'name' => name,
          'max_classification' => max_classification.to_s,
          'limits' => limits.transform_values { |value| value.dup }
        }
      end

      private

      def normalize_classification(value)
        value = value.to_sym
        return value if CLASSIFICATION_RANKS.key?(value)

        raise ValidationError, "classification must be one of #{CLASSIFICATION_RANKS.keys.join(', ')}"
      end

      def normalize_option(value, content_class)
        enabled, max_bytes = if value.is_a?(Hash)
                               [value.fetch(:enabled, value.fetch('enabled', false)),
                                value.fetch(:max_bytes, value.fetch('max_bytes', DEFAULT_MAX_BYTES))]
                             else
                               [value == true, DEFAULT_MAX_BYTES]
                             end
        unless max_bytes.is_a?(Integer) && max_bytes.positive? && max_bytes <= 1_048_576
          raise ValidationError, "#{content_class}: max_bytes must be between 1 and 1048576"
        end

        {enabled: !!enabled, max_bytes: max_bytes}.freeze
      end

      def refuse_restricted_capture!
        return unless max_classification == :restricted
        return unless limits.values.any? { |value| value.fetch(:enabled) }

        raise ValidationError, 'restricted classifications cannot enable content capture'
      end

      def canonical_document
        JSON.generate(
          'name' => name,
          'max_classification' => max_classification.to_s,
          'limits' => limits.transform_keys(&:to_s)
        )
      end

      def canonical_bytes(value)
        canonical = canonicalize(value, depth: 0)
        canonical.is_a?(String) ? canonical : JSON.generate(canonical)
      rescue JSON::GeneratorError, EncodingError => error
        raise ValidationError, "content is not serializable: #{error.message}"
      end

      def canonicalize(value, depth:)
        raise Tamoz::SensitiveValueError, 'Tamoz::Secret is not permitted in content' if value.is_a?(Tamoz::Secret)
        raise ValidationError, 'content nesting exceeds 64 levels' if depth > 64

        case value
        when Hash
          keys = value.keys.map(&:to_s)
          raise ValidationError, 'content has colliding string and symbol keys' unless keys.uniq.length == keys.length

          keys.sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            [key, canonicalize(value.fetch(original), depth: depth + 1)]
          end
        when Array
          raise ValidationError, 'content exceeds 100000 items' if value.length > 100_000

          value.map { |entry| canonicalize(entry, depth: depth + 1) }
        when String
          utf8 = value.encode(Encoding::UTF_8)
          raise ValidationError, 'content string exceeds 1048576 bytes' if utf8.bytesize > 1_048_576

          utf8
        when NilClass, TrueClass, FalseClass, Integer, Float
          raise ValidationError, 'content contains a non-finite float' if value.is_a?(Float) && !value.finite?

          value
        else
          raise ValidationError, "unsupported content value #{value.class}"
        end
      rescue EncodingError => error
        raise ValidationError, "invalid content encoding: #{error.message}"
      end

      def safe_truncate(bytes, limit)
        value = bytes.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8)
        value = value.byteslice(0, value.bytesize - 1).to_s while !value.valid_encoding? && value.bytesize.positive?
        value
      end

      NONE = new(name: 'none').freeze
    end
  end
end
