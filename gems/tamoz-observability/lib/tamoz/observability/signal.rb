# frozen_string_literal: true

module Tamoz
  module Observability
    # One immutable value, three kinds (design §6.3). The `timing`
    # discriminator separates a measured interval from a span whose durable
    # record carries no timestamps, so a consumer can tell "0 ms" from
    # "unmeasured" rather than reading a fabricated duration.
    class Signal
      KINDS = %i[event span measurement].freeze
      TIMINGS = %i[interval ordering_only point].freeze
      OUTCOMES = %i[ok error unknown].freeze
      MAX_ATTRIBUTES = 64
      MAX_ATTRIBUTE_STRING_BYTES = 4_096
      MAX_CONTENT_STRING_BYTES = 1_048_576
      MAX_CONTENT_DEPTH = 64

      attr_reader :kind, :name, :schema_version, :correlation, :timing,
                  :started_at_ms, :ended_at_ms, :observed_at_ms,
                  :attributes, :content, :policy_digest, :outcome, :error_class

      # rubocop:disable Metrics/ParameterLists -- one immutable value, one field list
      def self.build(kind:, name:, correlation:, timing:, observed_at_ms:,
                     started_at_ms: nil, ended_at_ms: nil, attributes: {},
                     content: nil, policy_digest: nil, outcome: :ok, error_class: nil,
                     schema_version: SCHEMA_VERSION)
        new(
          kind:, name:, schema_version:, correlation:, timing:,
          started_at_ms:, ended_at_ms:, observed_at_ms:,
          attributes:, content:, policy_digest:, outcome:, error_class:
        )
      end

      def initialize(kind:, name:, schema_version:, correlation:, timing:,
                     started_at_ms:, ended_at_ms:, observed_at_ms:,
                     attributes:, content:, policy_digest:, outcome:, error_class:)
        validate_memberships(kind, timing, outcome)
        validate_timing(timing, started_at_ms, ended_at_ms)
        validate_outcome(outcome, error_class)
        validate_required_scalars(schema_version, observed_at_ms)
        build_state(
          kind:, name:, schema_version:, correlation:, timing:,
          started_at_ms:, ended_at_ms:, observed_at_ms:,
          attributes:, content:, policy_digest:, outcome:, error_class:
        )
        freeze
      end
      # rubocop:enable Metrics/ParameterLists

      def duration_ms
        return nil unless timing == :interval

        ended_at_ms - started_at_ms
      end

      def to_h
        {
          'kind' => kind.to_s,
          'name' => name,
          'schema_version' => schema_version,
          'correlation' => stringify_keys(correlation),
          'timing' => timing.to_s,
          'started_at_ms' => started_at_ms,
          'ended_at_ms' => ended_at_ms,
          'observed_at_ms' => observed_at_ms,
          'duration_ms' => duration_ms,
          'attributes' => stringify_keys(attributes),
          'content' => content,
          'policy_digest' => policy_digest,
          'outcome' => outcome.to_s,
          'error_class' => error_class
        }.compact
      end

      private

      def validate_memberships(kind, timing, outcome)
        validate_membership(kind, KINDS, :kind)
        validate_membership(timing, TIMINGS, :timing)
        validate_membership(outcome, OUTCOMES, :outcome)
      end

      def validate_membership(value, permitted, field)
        return if permitted.include?(value)

        raise ValidationError, "#{field} must be one of #{permitted.join(', ')}"
      end

      def validate_timing(timing, started_at_ms, ended_at_ms)
        case timing
        when :interval
          unless started_at_ms.is_a?(Integer) && ended_at_ms.is_a?(Integer) && ended_at_ms >= started_at_ms
            raise ValidationError, 'an interval requires started_at_ms <= ended_at_ms'
          end
        when :ordering_only, :point
          unless started_at_ms.nil? && ended_at_ms.nil?
            raise ValidationError, "a #{timing} signal carries no interval bounds"
          end
        end
      end

      def validate_outcome(outcome, error_class)
        return if outcome == :ok ? error_class.nil? : !error_class.nil?

        raise ValidationError, 'error_class is required unless the outcome is :ok'
      end

      def validate_required_scalars(schema_version, observed_at_ms)
        unless schema_version.is_a?(Integer) && schema_version.positive?
          raise ValidationError, 'schema_version must be a positive integer'
        end
        raise ValidationError, 'observed_at_ms must be an integer' unless observed_at_ms.is_a?(Integer)
      end

      # rubocop:disable Metrics/ParameterLists -- build_state is a straight
      # field-by-field unpacking of the constructor's immutable value list.
      def build_state(kind:, name:, schema_version:, correlation:, timing:,
                      started_at_ms:, ended_at_ms:, observed_at_ms:,
                      attributes:, content:, policy_digest:, outcome:, error_class:)
        @kind = kind
        @name = String(name).freeze
        @schema_version = Integer(schema_version)
        @correlation = freeze_attributes(correlation, 'correlation')
        @timing = timing
        @started_at_ms = started_at_ms
        @ended_at_ms = ended_at_ms
        @observed_at_ms = Integer(observed_at_ms)
        @attributes = freeze_attributes(attributes, 'attributes')
        @content = content.nil? ? nil : freeze_content(content, 'content')
        @policy_digest = policy_digest&.to_s&.freeze
        @outcome = outcome
        @error_class = error_class&.to_s&.freeze
      end
      # rubocop:enable Metrics/ParameterLists

      def freeze_attributes(values, field)
        validate_attribute_hash!(values, field)
        values.to_h do |key, value|
          [normalize_key(key, field), freeze_value(value, "#{field}.#{key}")]
        end.freeze
      end

      def validate_attribute_hash!(values, field)
        raise ValidationError, "#{field} must be a Hash" unless values.is_a?(Hash)
        raise ValidationError, "#{field} exceeds #{MAX_ATTRIBUTES} entries" unless values.length <= MAX_ATTRIBUTES
      end

      def normalize_key(key, field)
        return key if key.is_a?(Symbol)
        return key.to_sym if key.is_a?(String) && !key.empty?

        raise ValidationError, "#{field} has an invalid key"
      end

      def freeze_value(value, path)
        case value
        when String then freeze_string_value(value, path)
        when Float then validate_finite_float!(value, path)
        when Integer, Symbol, TrueClass, FalseClass, NilClass then value
        else raise ValidationError, "#{path}: unsupported attribute value #{value.class}"
        end
      end

      def freeze_string_value(value, path)
        if value.bytesize > MAX_ATTRIBUTE_STRING_BYTES
          raise ValidationError, "#{path}: string exceeds #{MAX_ATTRIBUTE_STRING_BYTES} bytes"
        end

        value.dup.freeze
      end

      def validate_finite_float!(value, path)
        raise ValidationError, "#{path}: non-finite floats are unsupported" unless value.finite?

        value
      end

      def stringify_keys(values)
        values.to_h { |key, value| [key.to_s, value] }
      end

      def freeze_content(value, path, depth: 0)
        validate_content_entry!(value, path, depth)

        case value
        when Hash then freeze_content_hash(value, path, depth)
        when Array then freeze_content_array(value, path, depth)
        when String then freeze_content_string(value, path)
        when Float then validate_finite_float!(value, path)
        when Integer, Symbol, TrueClass, FalseClass, NilClass then value
        else raise ValidationError, "#{path}: unsupported value #{value.class}"
        end
      end

      def validate_content_entry!(value, path, depth)
        raise ValidationError, "#{path} nesting exceeds #{MAX_CONTENT_DEPTH} levels" if depth > MAX_CONTENT_DEPTH
        raise ValidationError, "#{path}: Tamoz::Secret is not permitted" if value.is_a?(Tamoz::Secret)
      end

      def freeze_content_hash(hash, path, depth)
        raise ValidationError, "#{path} exceeds #{MAX_ATTRIBUTES} entries" if hash.length > MAX_ATTRIBUTES

        hash.to_h do |key, entry|
          [key.to_s.freeze, freeze_content(entry, "#{path}.#{key}", depth: depth + 1)]
        end.freeze
      end

      def freeze_content_array(array, path, depth)
        raise ValidationError, "#{path} exceeds #{MAX_ATTRIBUTES} entries" if array.length > MAX_ATTRIBUTES

        array.map.with_index do |entry, index|
          freeze_content(entry, "#{path}[#{index}]", depth: depth + 1)
        end.freeze
      end

      def freeze_content_string(value, path)
        if value.bytesize > MAX_CONTENT_STRING_BYTES
          raise ValidationError, "#{path}: string exceeds #{MAX_CONTENT_STRING_BYTES} bytes"
        end

        value.dup.freeze
      end
    end
  end
end
