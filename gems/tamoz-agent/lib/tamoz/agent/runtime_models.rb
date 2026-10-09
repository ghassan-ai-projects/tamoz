# frozen_string_literal: true

module Tamoz
  module Agent
    # The `models:` section of a runtime's config; a role names the variable that holds its key, never the key.
    class RuntimeModels
      ConfiguredModel = Data.define(:provider, :model, :credential, :api_base)

      KEYED_FIELDS = %w[provider model credential api_base].freeze
      ROLE_FIELDS = { 'chat' => %w[provider model], 'transcription' => KEYED_FIELDS, 'vision' => KEYED_FIELDS }.freeze
      REQUIRED_FIELDS = %w[provider model].freeze
      PRINTABLE_NAME = /\A[a-z_]{1,40}\z/
      PROVIDER = /\A[a-z][a-z0-9_-]{0,39}\z/
      # No user, password or query: any of them would put a secret in the config.
      API_BASE = %r{\Ahttps?://[^/@\s?#]+(/[^\s?#]*)?\z}

      def self.parse(raw)
        return new({}) if raw.nil?
        raise ArgumentError, 'models must be a mapping of role names' unless raw.is_a?(Hash)

        new(raw.to_h { |role, fields| [role, read_role(role, fields)] })
      end

      def self.read_role(role, fields)
        allowed = ROLE_FIELDS.fetch(role) { raise ArgumentError, "models.#{printable_name(role)} is not a model role" }
        raise ArgumentError, "models.#{role} must be a mapping" unless fields.is_a?(Hash)

        unknown = (fields.keys - allowed).map { printable_name(_1) }
        raise ArgumentError, "models.#{role} does not take #{unknown.join(', ')}" if unknown.any?

        require_fields!(role, fields)
        configured_model(role, fields)
      end

      def self.configured_model(role, fields)
        ConfiguredModel.new(provider: provider!(role, fields['provider']), model: fields['model'],
                            credential: fields.key?('credential') ? credential!(role, fields['credential']) : nil,
                            api_base: fields.key?('api_base') ? api_base!(role, fields['api_base']) : nil)
      end

      def self.require_fields!(role, fields)
        missing = REQUIRED_FIELDS.find { |field| !fields[field].is_a?(String) || fields[field].strip.empty? }
        raise ArgumentError, "models.#{role}.#{missing} is required" if missing
      end

      def self.provider!(role, name)
        return name if name.match?(PROVIDER)

        raise ArgumentError, "models.#{role}.provider must be a provider name such as openrouter"
      end

      def self.credential!(role, name)
        return name if ModelClientFactory.role_credential?(name)

        raise ArgumentError, "models.#{role}.credential must name an *_API_KEY variable, never hold the key"
      end

      def self.api_base!(role, url)
        return url if url.is_a?(String) && url.match?(API_BASE)

        raise ArgumentError, "models.#{role}.api_base must be an http(s) URL without credentials or a query"
      end

      def self.printable_name(key) = key.is_a?(String) && key.match?(PRINTABLE_NAME) ? key : 'an unrecognised name'

      # A role moved to another provider starts afresh: its key and endpoint belonged to the old one.
      def self.merge(raw, changes)
        (raw || {}).merge(changes) do |_role, current, fields|
          fields.key?('provider') && fields['provider'] != current['provider'] ? fields : current.merge(fields)
        end
      end

      private_class_method :read_role, :configured_model, :require_fields!, :provider!, :credential!, :api_base!,
                           :printable_name

      def initialize(models)
        @models = models.freeze
        freeze
      end

      def [](role) = @models[role]

      NONE = new({})
    end
  end
end
