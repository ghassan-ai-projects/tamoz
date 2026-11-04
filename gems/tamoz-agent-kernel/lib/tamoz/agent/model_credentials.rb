# frozen_string_literal: true

require 'tamoz/agent/errors'
require 'tamoz/agent/providers'

module Tamoz
  module Agent
    # How a model client finds its credential: the profile reference or the provider's environment variable.
    module ModelCredentials
      ROLE_CREDENTIAL = /\A(?!TAMOZ_)[A-Z][A-Z0-9_]*_API_KEY\z/

      # A model role reads its key from the `*_API_KEY` variable it names, never from a runtime or channel one.
      def role_credential?(name) = name.is_a?(String) && name.match?(ROLE_CREDENTIAL)

      def environment_names(provider:, profile_role: nil, credential_name: nil)
        name = normalize_provider(provider)
        names = [role_credential_name(credential_name, profile_role) || credential_env_key(name),
                 api_base_name(name)]
        ref = profile_credential_reference(profile_role, name)
        names << ref.fetch('name') if ref
        names.uniq.freeze
      end

      def worker_environment(provider:, environment:, profile_role: nil, credential_name: nil)
        environment_names(provider:, profile_role:, credential_name:).each_with_object({}) do |name, selected|
          value = environment_value(environment, name)
          selected[name] = value unless value.nil?
        end
      end

      def credential_reference(provider:, profile_role:, environment:)
        name = normalize_provider(provider)
        credential_name = credential_name_for(profile_role, name)
        credential = environment_value(environment, credential_name)
        raise_credential_unavailable(profile_role, credential_name) if credential.to_s.empty? && name != 'ollama'

        return nil if name == 'ollama' && credential.to_s.empty?

        { 'kind' => 'env', 'name' => credential_name }
      end

      private

      def role_credential_name(name, profile_role)
        return nil if name.to_s.empty?
        raise ConfigurationError, 'a profile role names its credential in the profile' if profile_role
        unless role_credential?(name)
          raise ConfigurationError, 'a role credential must name an environment variable, never hold the key'
        end

        name
      end

      def credential_name_for(profile_role, provider)
        ref = profile_credential_reference(profile_role, provider)
        return credential_env_key(provider) unless ref

        ref.fetch('name')
      end

      def profile_credential_reference(profile_role, provider)
        return unless profile_role

        ref = profile_role.credential_ref
        return if ref.nil?
        unless ref.is_a?(Hash) && ref['kind'] == 'env' &&
               ref['name'].is_a?(String) && ref['name'].match?(/\A[A-Z][A-Z0-9_]*\z/)
          raise ProfileRoleUnavailableError, 'model_role/credential_reference_invalid'
        end
        if ref.fetch('name') == api_base_name(provider)
          raise ProfileRoleUnavailableError, 'model_role/credential_reference_invalid'
        end

        ref
      end

      def credential_env_key(provider)
        Providers::ENV_KEYS.fetch(provider.to_sym)
      end

      def api_base_name(provider)
        "#{provider.upcase}_API_BASE"
      end

      def ensure_credential!(value, provider, profile_role:, credential_name:)
        return if !value.to_s.empty? || provider == 'ollama'

        raise_credential_unavailable(profile_role, credential_name)
      end

      # The refusal names the role and the reference (DR-5 D1): the operator
      # pinned a specific credential, so the generic provider key is noise.
      def raise_credential_unavailable(profile_role, name)
        if profile_role
          raise ProfileRoleUnavailableError,
                "model_role/credential_unavailable: #{profile_role.name} (#{name})"
        end

        raise ModelCallError.new(code: 'credential_unavailable')
      end

      def environment_value(environment, name)
        return environment[name] if environment.respond_to?(:[])

        environment.to_h.fetch(name, nil)
      end
    end
  end
end
