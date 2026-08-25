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
      MAX_CONTENT_ENTRIES = 64

      attr_reader :name, :max_classification, :limits, :digest

      def initialize(name: 'none', max_classification: :internal, **options)
        @name = String(name).freeze
        @max_classification = normalize_classification(max_classification)
        @limits = build_limits(options)
        refuse_restricted_capture!
        @digest = compute_policy_digest
        freeze
      end

      def capture?(content_class)
        limits.fetch(content_class.to_sym).fetch(:enabled)
      end

      def max_bytes(content_class)
        limits.fetch(content_class.to_sym).fetch(:max_bytes)
      end

      def describe(content_class, value)
        content_class = validate_content_class(content_class)
        bytes = canonical_bytes(value)
        result = described_result(content_class, bytes)
        attach_capture!(result, content_class, bytes) if capture?(content_class)
        result
      end

      def apply(content)
        return {policy_digest: digest, content: {}} if content.nil?
        raise ValidationError, 'content must be a Hash keyed by content class' unless content.is_a?(Hash)

        content.each_with_object({policy_digest: digest, content: {}}) do |(key, value), result|
          result[:content].merge!(describe(key, value))
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

      def build_limits(options)
        CLASSES.to_h do |content_class|
          [content_class, normalize_option(options.fetch(content_class, false), content_class)]
        end.freeze
      end

      def compute_policy_digest
        "sha256:#{Digest::SHA256.hexdigest(canonical_document)}".freeze
      end

      def validate_content_class(content_class)
        content_class = content_class.to_sym
        return content_class if CLASSES.include?(content_class)

        raise ValidationError, "unknown content class #{content_class}"
      end

      def described_result(content_class, bytes)
        {
          "#{content_class}_digest" => content_digest(bytes),
          "#{content_class}_bytes" => bytes.bytesize
        }
      end

      def attach_capture!(result, content_class, bytes)
        limit = max_bytes(content_class)
        result[content_class.to_s] = safe_truncate(bytes, limit)
        result["#{content_class}_truncated"] = true if bytes.bytesize > limit
      end

      def content_digest(bytes)
        "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      end

      def normalize_classification(value)
        value = value.to_sym
        return value if CLASSIFICATION_RANKS.key?(value)

        raise ValidationError, "classification must be one of #{CLASSIFICATION_RANKS.keys.join(', ')}"
      end

      def normalize_option(value, content_class)
        enabled = parse_enabled(value)
        limit = parse_max_bytes(value)
        validate_max_bytes!(limit, content_class)

        {enabled: !!enabled, max_bytes: limit}.freeze
      end

      def parse_enabled(value)
        return value.fetch(:enabled, value.fetch('enabled', false)) if value.is_a?(Hash)

        value == true
      end

      def parse_max_bytes(value)
        return value.fetch(:max_bytes, value.fetch('max_bytes', DEFAULT_MAX_BYTES)) if value.is_a?(Hash)

        DEFAULT_MAX_BYTES
      end

      def validate_max_bytes!(limit, content_class)
        return if limit.is_a?(Integer) && limit.positive? && limit <= 1_048_576

        raise ValidationError, "#{content_class}: max_bytes must be between 1 and 1048576"
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
        serialize_canonical(canonicalize(value, depth: 0))
      rescue JSON::GeneratorError, EncodingError => error
        raise ValidationError, "content is not serializable: #{error.message}"
      end

      def serialize_canonical(canonical)
        canonical.is_a?(String) ? canonical : JSON.generate(canonical)
      end

      def canonicalize(value, depth:)
        guard_value!(value, depth)

        case value
        when Hash then canonicalize_hash(value, depth)
        when Array then canonicalize_array(value, depth)
        when String then canonicalize_string(value)
        when NilClass, TrueClass, FalseClass, Integer, Float then canonicalize_scalar(value)
        else raise ValidationError, "unsupported content value #{value.class}"
        end
      rescue EncodingError => error
        raise ValidationError, "invalid content encoding: #{error.message}"
      end

      def guard_value!(value, depth)
        raise Tamoz::SensitiveValueError, 'Tamoz::Secret is not permitted in content' if value.is_a?(Tamoz::Secret)
        raise ValidationError, 'content nesting exceeds 64 levels' if depth > 64
      end

      def canonicalize_hash(hash, depth)
        raise ValidationError, 'content exceeds 64 entries' if hash.length > MAX_CONTENT_ENTRIES

        canonicalize_sorted_keys(hash, depth)
      end

      def canonicalize_sorted_keys(hash, depth)
        keys = hash.keys.map(&:to_s)
        raise ValidationError, 'content has colliding string and symbol keys' unless keys.uniq.length == keys.length

        keys.sort.to_h do |key|
          [key, canonicalize(hash.fetch(resolve_original_key(hash, key)), depth: depth + 1)]
        end
      end

      def resolve_original_key(hash, string_key)
        return string_key if hash.key?(string_key)

        hash.keys.find { |candidate| candidate.to_s == string_key }
      end

      def canonicalize_array(array, depth)
        raise ValidationError, "content exceeds #{MAX_CONTENT_ENTRIES} items" if array.length > MAX_CONTENT_ENTRIES

        array.map { |entry| canonicalize(entry, depth: depth + 1) }
      end

      def canonicalize_string(string)
        utf8 = string.encode(Encoding::UTF_8)
        raise ValidationError, 'content string exceeds 1048576 bytes' if utf8.bytesize > 1_048_576

        utf8
      end

      def canonicalize_scalar(scalar)
        raise ValidationError, 'content contains a non-finite float' if scalar.is_a?(Float) && !scalar.finite?

        scalar
      end

      def safe_truncate(bytes, limit)
        repair_utf8_tail(truncate_to_limit(bytes, limit))
      end

      def truncate_to_limit(bytes, limit)
        bytes.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8)
      end

      def repair_utf8_tail(value)
        value = value.byteslice(0, value.bytesize - 1).to_s while !value.valid_encoding? && value.bytesize.positive?
        value
      end

      NONE = new(name: 'none').freeze
    end
  end
end
