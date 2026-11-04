# frozen_string_literal: true

require 'digest'
require 'tamoz/agent/episode_model_transport'
require 'tamoz/agent/model_credentials'
require 'tamoz/agent/model_receipt'
require 'tamoz/agent/model_route_checks'
require 'tamoz/agent/model_windows'
require 'tamoz/agent/providers'

module Tamoz
  module Agent
    # Builds model clients from the provider descriptors; native-protocol providers are rejected.
    module ModelClientFactory
      DESCRIPTORS = {
        'openai' => { default_base: 'https://api.openai.com/v1', protocol: 'openai-compatible', kind: 'direct' },
        'deepseek' => { default_base: 'https://api.deepseek.com', protocol: 'openai-compatible', kind: 'direct' },
        'openrouter' => { default_base: 'https://openrouter.ai/api/v1', protocol: 'openai-compatible',
                          kind: 'gateway' },
        'ollama' => { default_base: 'http://localhost:11434/v1', protocol: 'openai-compatible', kind: 'local' },
        'xai' => { default_base: 'https://api.x.ai/v1', protocol: 'openai-compatible', kind: 'direct' },
        'perplexity' => { default_base: 'https://api.perplexity.ai/v1', protocol: 'openai-compatible', kind: 'direct' },
        'mistral' => { default_base: 'https://api.mistral.ai/v1', protocol: 'openai-compatible', kind: 'direct' },
        'zai' => { default_base: 'https://api.z.ai/api/paas/v4', protocol: 'openai-compatible', kind: 'direct' },
        'anthropic' => { default_base: nil, protocol: 'native-rejected', kind: 'rejected' },
        'gemini' => { default_base: nil, protocol: 'native-rejected', kind: 'rejected' }
      }.transform_values(&:freeze).freeze

      extend ModelCredentials
      extend ModelRouteChecks

      class << self
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists -- one build: every ensure,
        # the configuration digest and the transport in the order a caller can read them.
        def build(provider:, model:, profile_role:, environment:, explicit_api_base: nil,
                  safety: :unsafe, gateway: nil, timeout_seconds: nil, context_window: nil, credential_name: nil,
                  pause: nil)
          name = normalize_provider(provider)
          descriptor = descriptor_for(name)
          ensure_model!(model, name)
          ensure_role_binding!(profile_role, name, model)
          ensure_protocol!(descriptor, name)
          credential_name = role_credential_name(credential_name, profile_role) ||
                            credential_name_for(profile_role, name)
          api_key = environment_value(environment, credential_name)
          endpoint = explicit_api_base || profile_endpoint(profile_role) ||
                     environment_value(environment, api_base_name(name)) || descriptor.fetch(:default_base)
          ensure_credential!(api_key, name, profile_role:, credential_name:)
          ensure_endpoint!(endpoint, name)
          safety = normalize_safety(safety)
          configuration = configuration_document(name, model, endpoint, profile_role, safety)
          EpisodeModelTransport.new(
            endpoint:, model:, provider: name, api_key:, safety:, gateway:,
            pause:,
            timeout_seconds: timeout_seconds || ModelWindows.request_timeout(provider: name, model:),
            context_window: context_window || configured_context_window(profile_role, environment, name, model),
            provider_configuration_digest: Tamoz::Core.digest(
              "tamoz.agent.model.configuration.v1\n", configuration
            )
          )
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists

        private

        # The routed model's window, explicit before implicit: a profile role setting, else the
        # operator's TAMOZ_CONTEXT_WINDOW, else the documented window for the route. There is no
        # built-in default; a caller that needs one refuses without it.
        def configured_context_window(profile_role, environment, provider, model)
          value = (profile_role&.normalized_settings || {})['context_window'] ||
                  environment_value(environment, 'TAMOZ_CONTEXT_WINDOW') ||
                  ModelWindows.window(provider:, model:)
          return unless value

          window = Integer(value, exception: false)
          raise ModelCallError.new(code: 'context_window_invalid') unless window&.positive?

          window
        end

        def normalize_provider(provider)
          value = String(provider).downcase
          return value if DESCRIPTORS.key?(value)

          raise ModelCallError.new(code: 'unsupported_provider')
        end

        def descriptor_for(provider)
          DESCRIPTORS.fetch(provider)
        end

        def profile_endpoint(profile_role)
          settings = profile_role&.normalized_settings || {}
          settings['base_url'] || settings['api_base']
        end

        def configuration_document(provider, model, endpoint, role, safety)
          {
            'provider' => provider,
            'model' => model,
            'endpoint' => endpoint,
            'protocol' => descriptor_for(provider).fetch(:protocol),
            'settings' => EpisodeModelTransport::SETTINGS,
            'profile_role' => role_document(role),
            'profile_digest' => role&.profile_digest,
            'safety' => safety.to_s
          }
        end

        def role_document(role)
          return nil unless role

          {
            'name' => role.name,
            'provider' => role.provider,
            'model' => role.model,
            'revision' => role.revision,
            'normalized_settings' => role.normalized_settings,
            'credential_ref' => role.credential_ref&.slice('kind', 'name'),
            'profile_digest' => role.profile_digest
          }
        end
      end
    end
  end
end
