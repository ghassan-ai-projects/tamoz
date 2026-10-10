# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # The model client a command runs with.
      class ModelBuilder
        DEFAULT_PROVIDER = 'openai'
        MISSING_MODEL = '--model, or models.chat in the runtime config'
        PAIRED_OVERRIDE = "pass --provider and --model together to run another model than the runtime's chat model"

        def initialize(env:, factory: nil)
          @env = env
          @factory = factory
          @runtime_chat_models = {}
        end

        def build(options, profile: nil)
          return @factory.call(options) if @factory

          chosen = chosen_model(options)
          primary = profile_roles(profile, chosen)['primary']
          model_name = chosen[:model] || primary&.fetch('model')
          raise OptionParser::MissingArgument, MISSING_MODEL if model_name.to_s.empty?

          provider = (chosen[:provider] || primary&.fetch('provider')).to_s
          ModelClientFactory.build(
            provider: provider.empty? ? DEFAULT_PROVIDER : provider, model: model_name,
            profile_role: model_role_for(profile, primary), environment: @env, safety: :unsafe
          )
        end

        def resolve_profile_roles(profile, options)
          return {} unless profile

          profile_roles(profile, chosen_model(options))
        end

        private

        # Over a runtime model the provider and the model are named together, so one is never paired with the other's.
        def chosen_model(options)
          named = named_model(options)
          return named if named.values.all?

          chat = named.values.any? ? readable_runtime_chat_model(options) : runtime_chat_model(options)
          return named unless chat
          raise OptionParser::MissingArgument, PAIRED_OVERRIDE if named.values.any?

          { model: chat.model, provider: chat.provider }
        end

        def named_model(options)
          {
            model: non_empty(options[:model]),
            provider: non_empty(options[:provider])
          }
        end

        # Read once per process, so a running worker keeps the model it started with.
        def runtime_chat_model(options)
          path = non_empty(options[:runtime_dir]) || non_empty(@env['TAMOZ_RUNTIME_DIR'])
          return nil unless path

          path = canonical(path)
          @runtime_chat_models.fetch(path) do
            @runtime_chat_models[path] = RuntimeDirectory.resolve(path:, env: @env).models['chat']
          end
        end

        # A run that names its own model needs the runtime only to refuse a half-named pair.
        def readable_runtime_chat_model(options)
          runtime_chat_model(options)
        rescue RuntimeDirectory::Error
          nil
        end

        def canonical(path)
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end

        def non_empty(value) = value.to_s.empty? ? nil : value

        def profile_roles(profile, chosen)
          return {} unless profile

          profile.model_roles.to_h do |name, role|
            entry = { 'provider' => String(role.fetch('provider')), 'model' => String(role.fetch('model')) }
            [name, name == 'primary' ? override_primary(entry, chosen) : entry]
          end
        end

        def override_primary(entry, chosen)
          { 'model' => chosen[:model], 'provider' => chosen[:provider] }.each do |field, value|
            next unless value

            reject_secret_shaped_override!(field, value)
            entry[field] = String(value)
          end
          entry
        end

        def reject_secret_shaped_override!(field, value)
          case Profile.secret_shape(field, value)
          when :secret
            raise ProfilePolicyError,
                  "override for profile role \"primary\" field #{field.inspect} " \
                  'matches the embedded-secret pattern and cannot be recorded in profile_roles'
          when :candidate_secret
            raise ProfilePolicyError,
                  "override for profile role \"primary\" field #{field.inspect} is a " \
                  '40+ character high-entropy value (candidate secret). Pin an explicit ' \
                  'identifier with --model/--provider if this value is a legitimate model id.'
          end
        end

        def model_role_for(profile, primary)
          return unless profile && primary

          role = profile.model_roles.fetch('primary')
          own_provider = role['provider'] == primary.fetch('provider')
          ModelCall::ModelRole.new(
            name: 'primary', provider: primary.fetch('provider'), model: primary.fetch('model'),
            revision: role['revision'], normalized_settings: own_provider ? role['normalized_settings'] || {} : {},
            credential_ref: own_provider ? role['credential_ref'] : nil, profile_digest: profile.canonical_digest
          )
        end
      end
    end
  end
end
