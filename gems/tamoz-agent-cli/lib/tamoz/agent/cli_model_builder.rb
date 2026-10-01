# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # Builds the model client a command runs with, under §5.3 precedence:
      # CLI flag > TAMOZ_MODEL/TAMOZ_PROVIDER > the profile's primary role.
      class ModelBuilder
        def initialize(env:, factory: nil)
          @env = env
          @factory = factory
        end

        def build(options, profile: nil)
          return @factory.call(options) if @factory

          primary = resolve_profile_roles(profile, options)['primary']
          model_name = overridden_model(options) || primary&.fetch('model')
          raise OptionParser::MissingArgument, '--model or TAMOZ_MODEL' if model_name.to_s.empty?

          provider = (overridden_provider(options) || primary&.fetch('provider')).to_s
          ModelClientFactory.build(
            provider: provider.empty? ? 'openai' : provider, model: model_name,
            profile_role: model_role_for(profile, primary), environment: @env, safety: :unsafe
          )
        end

        # DR-5 D1: ONE resolution path for both `build` and the recorded
        # `profile_roles`, so the record is exactly what the run used. Only
        # :primary takes overrides; every other role keeps its file value.
        #
        # DR-5 RC6: an override entering the durable record is gated by the same
        # secret predicates profiles validate against (invariant 24).
        def resolve_profile_roles(profile, options)
          return {} unless profile

          profile.model_roles.to_h do |name, role|
            entry = { 'provider' => String(role.fetch('provider')), 'model' => String(role.fetch('model')) }
            [name, name == 'primary' ? override_primary(entry, options) : entry]
          end
        end

        private

        def overridden_model(options) = options[:model] || @env['TAMOZ_MODEL']

        def overridden_provider(options) = options[:provider] || @env['TAMOZ_PROVIDER']

        def override_primary(entry, options)
          { 'model' => overridden_model(options), 'provider' => overridden_provider(options) }.each do |field, value|
            next unless value

            entry[field] = String(value)
            reject_secret_shaped_override!(field, value)
          end
          entry
        end

        def reject_secret_shaped_override!(field, value)
          if Profile::SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
            raise ProfilePolicyError,
                  "override for profile role \"primary\" field #{field.inspect} " \
                  'matches the embedded-secret pattern and cannot be recorded in profile_roles'
          end
          return unless Profile::ENTROPY_PATTERN.match?(value) && !Profile::ENTROPY_EXEMPT_KEYS.include?(field)

          raise ProfilePolicyError,
                "override for profile role \"primary\" field #{field.inspect} is a " \
                '40+ character high-entropy value (candidate secret). Pin an explicit ' \
                'identifier with --model/--provider if this value is a legitimate model id.'
        end

        def model_role_for(profile, primary)
          return unless profile && primary

          role = profile.model_roles.fetch('primary')
          ModelCall::ModelRole.new(
            name: 'primary', provider: primary.fetch('provider'), model: primary.fetch('model'),
            revision: role['revision'], normalized_settings: role['normalized_settings'] || {},
            credential_ref: role['credential_ref'], profile_digest: profile.canonical_digest
          )
        end
      end
    end
  end
end
