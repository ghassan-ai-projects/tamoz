# frozen_string_literal: true

module Tamoz
  module Observability
    # The closed, versioned registry of every signal name any gem may emit
    # (design §6.1). Registration happens at load; lookup of an unregistered
    # name, duplicate registration, attribute-set drift without a `since`
    # bump, and a metric label that is a correlation identifier all raise.
    class SignalCatalog
      NAME_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
      PERMITTED_PREFIXES = %w[tamoz. comms. stream. scheduler. mcp.].freeze
      CORRELATION_IDENTIFIERS = %i[
        thread_id execution_id request_id occurrence_id task_id effect_key span_id trace_id
      ].freeze
      ATTRIBUTE_TYPES = %i[integer boolean string low_cardinality enum digest timestamp_ms].freeze
      STABILITIES = %i[stable experimental].freeze

      Entry = Data.define(
        :name, :kind, :since, :stability, :safety_bearing,
        :correlation, :required, :optional, :content
      )

      def initialize
        @entries = {}
      end

      # rubocop:disable Metrics/ParameterLists -- the registration shape of design §6.1
      def event(name, since:, stability:, safety_bearing:, correlation:, required:, optional: {}, content: [])
        register(
          :event, name,
          since:, stability:, safety_bearing:, correlation:, required:, optional:, content:
        )
      end
      # rubocop:enable Metrics/ParameterLists

      def measurement(name, since:, stability:, labels: [])
        forbidden = labels.map(&:to_sym) & CORRELATION_IDENTIFIERS
        unless forbidden.empty?
          raise ValidationError, "#{name}: correlation identifiers are not metric labels: #{forbidden.join(', ')}"
        end

        register(
          :measurement, name,
          since:, stability:, safety_bearing: false, correlation: [],
          required: {}, optional: labels.to_h { |label| [label.to_sym, :low_cardinality] }, content: []
        )
      end

      def fetch(name)
        @entries.fetch(name.to_s) do
          raise UnregisteredSignalError, "#{name} is not a registered signal"
        end
      end

      def registered?(name)
        @entries.key?(name.to_s)
      end

      def names
        @entries.keys.sort.freeze
      end

      def entries
        @entries.values.sort_by(&:name).freeze
      end

      def validate_signal(signal)
        entry = fetch(signal.name)
        raise ValidationError, "#{signal.name}: kind must be #{entry.kind}" unless signal.kind == entry.kind
        raise ValidationError, "#{signal.name}: schema version must be #{entry.since}" unless signal.schema_version >= entry.since

        correlation = signal.correlation.keys.map(&:to_sym)
        unknown = correlation - CORRELATION_IDENTIFIERS
        raise ValidationError, "#{signal.name}: unknown correlation keys: #{unknown.join(', ')}" unless unknown.empty?
        missing = entry.correlation - correlation
        raise ValidationError, "#{signal.name}: missing correlation keys: #{missing.join(', ')}" unless missing.empty?

        attributes = signal.attributes
        required = entry.required.keys
        missing = required - attributes.keys.map(&:to_sym)
        raise ValidationError, "#{signal.name}: missing required attributes: #{missing.join(', ')}" unless missing.empty?

        allowed = (entry.required.keys + entry.optional.keys).map(&:to_sym)
        unknown = attributes.keys.map(&:to_sym) - allowed
        raise ValidationError, "#{signal.name}: unknown attributes: #{unknown.join(', ')}" unless unknown.empty?

        declarations = entry.required.merge(entry.optional)
        attributes.each do |key, value|
          type = declarations.fetch(key.to_sym)
          validate_attribute_type!(signal.name, key, value, type)
        end

        content = signal.content || {}
        content_classes = content.keys.map do |key|
          key.to_s.sub(/_(?:digest|bytes|truncated)\z/, '').to_sym
        end.uniq
        unknown_content = content_classes - entry.content
        unless unknown_content.empty?
          raise ValidationError, "#{signal.name}: unsupported content classes: #{unknown_content.join(', ')}"
        end

        signal
      end

      def safety_bearing?(name)
        fetch(name).safety_bearing
      end

      private

      # rubocop:disable Metrics/ParameterLists
      def register(kind, name, since:, stability:, safety_bearing:, correlation:, required:, optional:, content:)
        name = validate_name(name)
        unless since.is_a?(Integer) && since.positive?
          raise ValidationError, "#{name}: since must be a positive integer"
        end
        validate_stability(stability)
        attributes = validate_attributes(required, optional)
        correlation = correlation.map(&:to_sym).freeze
        unknown = correlation - CORRELATION_IDENTIFIERS
        raise ValidationError, "#{name}: unknown correlation keys: #{unknown.join(', ')}" unless unknown.empty?

        entry = Entry.new(
          name:, kind:, since:, stability:, safety_bearing:,
          correlation:, required: attributes.fetch(:required),
          optional: attributes.fetch(:optional), content: content.map(&:to_sym).freeze
        )
        store(entry)
      end
      # rubocop:enable Metrics/ParameterLists

      def store(entry)
        existing = @entries[entry.name]
        if existing
          signature = existing.to_h.except(:name, :since) == entry.to_h.except(:name, :since)
          raise DuplicateSignalError, "#{entry.name} is already registered" if signature
          unless entry.since > existing.since
            raise SchemaEvolutionError,
                  "#{entry.name}: attribute set changed without a schema-version bump"
          end
        end
        @entries[entry.name] = entry
        entry
      end

      def validate_name(name)
        name = name.to_s
        raise ValidationError, "#{name}: not a safe, stable signal identifier" unless name.match?(NAME_PATTERN)
        unless PERMITTED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
          raise ValidationError, "#{name}: outside the permitted prefixes #{PERMITTED_PREFIXES.join(' ')}"
        end

        name
      end

      def validate_stability(stability)
        return if STABILITIES.include?(stability)

        raise ValidationError, "stability must be one of #{STABILITIES.join(', ')}"
      end

      def validate_attributes(required, optional)
        {
          required: typed_attributes(required),
          optional: typed_attributes(optional)
        }
      end

      def typed_attributes(declarations)
        declarations.to_h do |attribute, type|
          type = type.to_sym
          raise ValidationError, "#{attribute}: unknown attribute type #{type}" unless ATTRIBUTE_TYPES.include?(type)

          [attribute.to_sym, type]
        end.freeze
      end

      def validate_attribute_type!(name, key, value, type)
        valid = case type
                when :integer, :timestamp_ms then value.is_a?(Integer)
                when :boolean then value == true || value == false
                when :string, :low_cardinality, :enum, :digest then value.is_a?(String) || value.is_a?(Symbol)
                else false
                end
        if type == :digest
          valid &&= value.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        end
        raise ValidationError, "#{name}.#{key}: expected #{type}" unless valid
      end
    end
  end
end
