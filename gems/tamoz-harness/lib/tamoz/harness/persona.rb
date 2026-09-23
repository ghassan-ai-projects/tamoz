# frozen_string_literal: true

module Tamoz
  module Harness
    # Operator persona and preferences: trusted operator data, rendered into the header.
    module Persona
      VERBOSITIES = %w[quiet normal detailed].freeze
      DEPTHS = %w[low medium high].freeze
      KEYS = %w[language verbosity reasoning_depth].freeze

      module_function

      def sections(persona: nil, preferences: {})
        list = []
        if persona && !persona.strip.empty?
          list << ContextEngine::Section.new(name: 'persona', order: 700,
                                             text: persona)
        end
        rendered = render(preferences)
        list << ContextEngine::Section.new(name: 'preferences', order: 800, text: rendered) if rendered
        list
      end

      def validate!(preferences)
        unknown = preferences.keys.map(&:to_s) - KEYS
        raise Error, "unknown preference keys: #{unknown.join(', ')}" unless unknown.empty?

        check!(preferences, 'verbosity', VERBOSITIES)
        check!(preferences, 'reasoning_depth', DEPTHS)
        language = preferences['language']
        raise Error, 'language must be a short language tag' if language && !language.to_s.match?(/\A[A-Za-z-]{2,16}\z/)

        preferences
      end

      def render(preferences)
        values = validate!(preferences.transform_keys(&:to_s)).slice(*KEYS).compact
        return nil if values.empty?

        format(PromptPack.fetch('preferences'), values: values.map do |key, value|
          "#{key.tr('_', ' ')}: #{value}"
        end.join('; '))
      end

      def update(key, value) = format(PromptPack.fetch('operator_update'), key: key.to_s.tr('_', ' '), value:)

      def check!(preferences, key, allowed)
        value = preferences[key]
        raise Error, "#{key} must be one of #{allowed.join(', ')}" if value && !allowed.include?(value)
      end
      private_class_method :check!
    end
  end
end
