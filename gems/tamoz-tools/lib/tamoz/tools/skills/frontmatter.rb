# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # Parses and validates a skill manifest's YAML frontmatter.
      # :reek:MissingSafeMethod — validators raise the existing `Rejected` error;
      # predicate twins would allow callers to ignore invalid frontmatter.
      # :reek:ControlParameter — `required:` is part of the existing field-schema
      # call and preserves which absent field is rejected first.
      # :reek:FeatureEnvy — field validators necessarily inspect candidate values.
      # :reek:LongParameterList — `string!` carries the field, its schema name,
      # presence policy, and byte limit; bundling these fixed rules adds no value.
      # :reek:NilCheck — nil means an optional field is absent in this wire format.
      # :reek:RepeatedConditional — three independent optional fields share that
      # wire-format meaning; centralizing it would obscure their distinct defaults.
      # :reek:TooManyStatements — each validator is one ordered refusal gauntlet.
      # :reek:TooManyMethods — the methods are the manifest's distinct field rules;
      # moving them again would fragment one parser without another consumer.
      # :reek:UncommunicativeVariableName — RuboCop requires `e` for rescued errors.
      # :reek:UtilityFunction — pure shape predicates belong beside the refusal
      # methods that name their stable error contracts.
      class Frontmatter
        PORTABLE_KEYS = %w[name description license compatibility metadata allowed-tools].freeze
        KNOWN_EXTENSIONS = %w[tamoz.risk tamoz.eval-suite].freeze

        def initialize(text, label, limits)
          @text = text
          @label = label
          @limits = limits
        end

        def call
          scan!
          data = parse
          unless data.is_a?(Hash) && data.keys.all?(String)
            reject!('skill_frontmatter_invalid', 'frontmatter must be a mapping with string keys')
          end

          {
            'name' => string!(data, 'name', required: true, limit: 64),
            'description' => description(data),
            'license' => string!(data, 'license', required: false, limit: 128),
            'compatibility' => string!(data, 'compatibility', required: false, limit: 512),
            'metadata' => metadata(data),
            'allowed-tools' => requested_capabilities(data),
            'extra' => extra(data),
            'raw' => data
          }
        end

        private

        # Pass one: reject the load-time execution vectors before a data model
        # exists. Skills allow *zero* aliases (profiles allow 32) because a skill has
        # no legitimate use for indirection.
        def scan!
          FrontmatterScanner.new(@text, @label).call
        end

        # Pass two. An empty permitted-class list cannot materialize a non-core
        # object; `aliases: false` is belt to pass one's braces.
        def parse
          Psych.safe_load(@text, permitted_classes: [], permitted_symbols: [], aliases: false)
        rescue Psych::Exception => e
          reject!('skill_frontmatter_invalid', "invalid YAML: #{e.class}")
        end

        def description(data)
          value = string!(data, 'description', required: true, limit: @limits.fetch(:max_description_bytes))
          if value.match?(/[[:cntrl:]]/) && !value.match?(/\A[^\x00-\x08\x0B-\x1F\x7F]*\z/)
            reject!('skill_description_invalid', 'description contains control characters')
          end

          value
        end

        def string!(data, key, required:, limit:)
          value = data[key]
          if value.nil?
            reject!('skill_field_invalid', "#{key} is required") if required
            return nil
          end
          unless valid_string?(value, limit)
            reject!('skill_field_invalid', "#{key} must be a string of at most #{limit} bytes")
          end
          if key == 'name' && !NAME_PATTERN.match?(value)
            reject!('skill_name_invalid', 'name is not a valid skill name')
          end

          value
        end

        def valid_string?(value, limit)
          value.is_a?(String) && !value.empty? && value.bytesize <= limit &&
            value.valid_encoding? && !value.include?("\0")
        end

        def metadata(data)
          value = data.fetch('metadata', {})
          return {} if value.nil?

          unless value.is_a?(Hash) && value.length <= @limits.fetch(:max_metadata_pairs)
            reject!('skill_metadata_invalid', 'metadata must be a mapping of at most 32 pairs')
          end

          value.each { |key, entry| validate_metadata_pair!(key, entry) }
          value
        end

        def validate_metadata_pair!(key, entry)
          reject!('skill_metadata_invalid', 'invalid metadata key') unless valid_metadata_key?(key)
          reject!('skill_metadata_invalid', 'metadata values must be short strings') unless valid_metadata_value?(entry)
          return unless key.start_with?('tamoz.')

          unless KNOWN_EXTENSIONS.include?(key)
            reject!('skill_metadata_unknown_extension', "unknown extension key #{key}")
          end
          return unless key == 'tamoz.risk' && !DECLARED_RISKS.include?(entry)

          reject!('skill_metadata_invalid', "tamoz.risk must be one of #{DECLARED_RISKS.join(', ')}")
        end

        def valid_metadata_key?(key)
          key.is_a?(String) && METADATA_KEY_PATTERN.match?(key)
        end

        def valid_metadata_value?(entry)
          entry.is_a?(String) && entry.bytesize <= @limits.fetch(:max_metadata_value_bytes) &&
            entry.valid_encoding? && !entry.include?("\0")
        end

        # The author's requested upper bound and nothing else. It is recorded and
        # rendered; it never reaches Toolbox's tool set.
        def requested_capabilities(data)
          value = data['allowed-tools']
          return [] if value.nil?

          list = requested_list(value)
          reject!('skill_field_invalid', 'allowed-tools entries must be tool names') unless valid_requested_list?(list)

          list.uniq.sort
        end

        def requested_list(value)
          case value
          when String then value.split(',').map(&:strip).reject(&:empty?)
          when Array then value
          else reject!('skill_field_invalid', 'allowed-tools must be a list or comma-separated string')
          end
        end

        def valid_requested_list?(list)
          list.length <= @limits.fetch(:max_requested_capabilities) &&
            list.all? { |name| name.is_a?(String) && TOOL_PATTERN.match?(name) }
        end

        # Unknown portable fields are retained for round-trip compatibility and
        # ignored for authority (SKILLS_DESIGN §2).
        def extra(data)
          unknown = data.except(*PORTABLE_KEYS)
          if unknown.length > @limits.fetch(:max_extra_keys)
            reject!('skill_field_invalid', 'too many unknown frontmatter fields')
          end
          serialized = JSON.generate(Skills.canonical(unknown))
          if serialized.bytesize > @limits.fetch(:max_extra_bytes)
            reject!('skill_extra_bytes_exceeded', 'unknown frontmatter fields exceed the byte limit')
          end

          unknown
        rescue JSON::GeneratorError
          reject!('skill_field_invalid', 'unknown frontmatter fields are not serializable')
        end

        def reject!(code, detail)
          raise Rejected.new(code, @label, detail)
        end
      end
    end
  end
end
