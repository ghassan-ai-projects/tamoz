# frozen_string_literal: true

module Tamoz
  module Skills
    # A SKILL.md's YAML frontmatter, read in two passes: the scanner refuses aliases, tags and duplicate keys from
    # parser events; then `safe_load` with no permitted classes builds plain data, field by field validated.
    class Frontmatter
      PORTABLE_KEYS = %w[name description license compatibility metadata allowed-tools].freeze
      KNOWN_EXTENSIONS = %w[tamoz.risk tamoz.eval-suite].freeze
      # Whitespace (the spec) or commas (Claude Code) separate tools; a scope in parentheses may hold spaces.
      TOOL_TOKEN = /[^\s,(]+(?:\([^)]*\))?/
      CONTROL_CHARACTERS = /[\x00-\x08\x0B-\x1F\x7F]/

      def initialize(text, label, limits)
        @text = text
        @label = label
        @limits = limits
      end

      def call
        FrontmatterScanner.new(@text, @label).call
        data = parse
        { 'name' => name(data), 'description' => description(data),
          'license' => optional_string(data, 'license', 128),
          'compatibility' => optional_string(data, 'compatibility', @limits.fetch(:max_compatibility_chars)),
          'metadata' => metadata(data), 'allowed-tools' => requested_tools(data), 'extra' => extra(data),
          'raw' => data }
      end

      private

      def parse
        data = Psych.safe_load(@text, permitted_classes: [], permitted_symbols: [], aliases: false)
        return data if data.is_a?(Hash) && data.keys.all?(String)

        reject!('skill_frontmatter_invalid', 'frontmatter must be a mapping with string keys')
      rescue Psych::Exception => e
        reject!('skill_frontmatter_invalid', "invalid YAML: #{e.class}")
      end

      def name(data)
        value = required_string(data, 'name', 64)
        reject!('skill_name_invalid', 'name is not a valid skill name') unless NAME_PATTERN.match?(value)
        value
      end

      def description(data)
        value = required_string(data, 'description', @limits.fetch(:max_description_chars))
        if value.match?(CONTROL_CHARACTERS)
          reject!('skill_description_invalid',
                  'description contains control characters')
        end
        value
      end

      def required_string(data, key, limit)
        reject!('skill_field_invalid', "#{key} is required") if data[key].nil?
        optional_string(data, key, limit)
      end

      def optional_string(data, key, limit)
        value = data[key]
        return nil if value.nil?
        return value if value.is_a?(String) && !value.empty? && value.length <= limit && clean?(value)

        reject!('skill_field_invalid', "#{key} must be a string of at most #{limit} characters")
      end

      def metadata(data)
        value = data.fetch('metadata', {}) || {}
        unless value.is_a?(Hash) && value.length <= @limits.fetch(:max_metadata_pairs)
          reject!('skill_metadata_invalid', 'metadata must be a mapping of at most 32 pairs')
        end

        value.each { |key, entry| check_metadata_pair!(key, entry) }
      end

      def check_metadata_pair!(key, entry)
        unless key.is_a?(String) && METADATA_KEY_PATTERN.match?(key)
          reject!('skill_metadata_invalid',
                  'invalid metadata key')
        end
        unless entry.is_a?(String) && entry.bytesize <= @limits.fetch(:max_metadata_value_bytes) && clean?(entry)
          reject!('skill_metadata_invalid', 'metadata values must be short strings')
        end
        check_extension!(key, entry) if key.start_with?('tamoz.')
      end

      def check_extension!(key, entry)
        unless KNOWN_EXTENSIONS.include?(key)
          reject!('skill_metadata_unknown_extension',
                  "unknown extension key #{key}")
        end
        return unless key == 'tamoz.risk' && !DECLARED_RISKS.include?(entry)

        reject!('skill_metadata_invalid', "tamoz.risk must be one of #{DECLARED_RISKS.join(', ')}")
      end

      # The author's requested upper bound: recorded and rendered, never part of any tool set.
      def requested_tools(data)
        value = data['allowed-tools']
        return [] if value.nil?

        list = tool_list(value)
        unless list.length <= @limits.fetch(:max_requested_capabilities) &&
               list.all? { |tool| tool.is_a?(String) && TOOL_PATTERN.match?(tool) }
          reject!('skill_field_invalid', 'allowed-tools entries must be tool names')
        end
        list.uniq.sort
      end

      def tool_list(value)
        return value.scan(TOOL_TOKEN) if value.is_a?(String)
        return value if value.is_a?(Array)

        reject!('skill_field_invalid', 'allowed-tools must be a list or comma-separated string')
      end

      # Unknown portable fields are kept for round-trips and ignored for authority.
      def extra(data)
        unknown = data.except(*PORTABLE_KEYS)
        if unknown.length > @limits.fetch(:max_extra_keys)
          reject!('skill_field_invalid',
                  'too many unknown frontmatter fields')
        end
        if JSON.generate(Skills.canonical(unknown)).bytesize > @limits.fetch(:max_extra_bytes)
          reject!('skill_extra_bytes_exceeded', 'unknown frontmatter fields exceed the byte limit')
        end
        unknown
      rescue JSON::GeneratorError
        reject!('skill_field_invalid', 'unknown frontmatter fields are not serializable')
      end

      def clean?(value) = value.valid_encoding? && !value.include?("\0")

      def reject!(code, detail) = raise(Rejected.new(code, @label, detail))
    end
  end
end
