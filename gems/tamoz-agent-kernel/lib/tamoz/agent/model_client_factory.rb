# frozen_string_literal: true

require "digest"
require "tamoz/agent/episode_model_transport"
require "tamoz/agent/model_receipt"
require "tamoz/agent/providers"

module Tamoz
  module Agent
    module ModelClientFactory
      DESCRIPTORS = {
        "openai" => {default_base: "https://api.openai.com/v1", protocol: "openai-compatible", kind: "direct"},
        "deepseek" => {default_base: "https://api.deepseek.com", protocol: "openai-compatible", kind: "direct"},
        "openrouter" => {default_base: "https://openrouter.ai/api/v1", protocol: "openai-compatible", kind: "gateway"},
        "ollama" => {default_base: "http://localhost:11434/v1", protocol: "openai-compatible", kind: "local"},
        "xai" => {default_base: "https://api.x.ai/v1", protocol: "openai-compatible", kind: "direct"},
        "perplexity" => {default_base: "https://api.perplexity.ai/v1", protocol: "openai-compatible", kind: "direct"},
        "mistral" => {default_base: "https://api.mistral.ai/v1", protocol: "openai-compatible", kind: "direct"},
        "anthropic" => {default_base: nil, protocol: "native-rejected", kind: "rejected"},
        "gemini" => {default_base: nil, protocol: "native-rejected", kind: "rejected"}
      }.transform_values(&:freeze).freeze

      class << self
        def build(provider:, model:, profile_role:, environment:, explicit_api_base: nil,
                  safety: :unsafe, gateway: nil, timeout_seconds: 120)
          name = normalize_provider(provider)
          descriptor = descriptor_for(name)
          ensure_model!(model, name)
          ensure_role_binding!(profile_role, name, model)
          ensure_protocol!(descriptor, name)
          credential_name = credential_name_for(profile_role, name)
          api_key = environment_value(environment, credential_name)
          endpoint = explicit_api_base || profile_endpoint(profile_role) ||
            environment_value(environment, api_base_name(name)) || descriptor.fetch(:default_base)
          ensure_credential!(api_key, name, profile_role:, credential_name:)
          ensure_endpoint!(endpoint, name)
          safety = normalize_safety(safety)
          configuration = configuration_document(
            name, model, endpoint, descriptor, profile_role, safety
          )
          EpisodeModelTransport.new(
            endpoint:, model:, provider: name, api_key:, safety:,
            gateway:, timeout_seconds:,
            provider_configuration_digest: Tamoz::Core.digest(
              "tamoz.agent.model.configuration.v1\n", configuration
            )
          )
        end

        def environment_names(provider:, profile_role: nil)
          name = normalize_provider(provider)
          names = [credential_env_key(name), api_base_name(name)]
          ref = profile_credential_reference(profile_role, name)
          names << ref.fetch("name") if ref
          names.uniq.freeze
        end

        def worker_environment(provider:, profile_role: nil, environment:)
          environment_names(provider:, profile_role:).each_with_object({}) do |name, selected|
            value = environment_value(environment, name)
            selected[name] = value unless value.nil?
          end
        end

        def credential_reference(provider:, profile_role:, environment:)
          name = normalize_provider(provider)
          credential_name = credential_name_for(profile_role, name)
          credential = environment_value(environment, credential_name)
          if credential.to_s.empty? && name != "ollama"
            raise_credential_unavailable(profile_role, credential_name)
          end

          return nil if name == "ollama" && credential.to_s.empty?

          {"kind" => "env", "name" => credential_name}
        end

        private

        def normalize_provider(provider)
          value = String(provider).downcase
          return value if DESCRIPTORS.key?(value)

          raise ModelCallError.new(code: "unsupported_provider")
        end

        def descriptor_for(provider)
          DESCRIPTORS.fetch(provider)
        end

        def ensure_model!(model, provider)
          return if model.is_a?(String) && !model.empty? &&
                    (provider != "openrouter" || model.include?("/"))

          code = model.is_a?(String) && !model.empty? ? "model_invalid" : "model_required"
          raise ModelCallError.new(code:)
        end

        def ensure_role_binding!(role, provider, model)
          return unless role
          return if role.provider.to_s == provider && role.model.to_s == model

          raise ModelCallError.new(code: "profile_role_mismatch")
        end

        def ensure_protocol!(descriptor, provider)
          return unless descriptor.fetch(:kind) == "rejected"

          raise ModelCallError.new(code: "native_protocol_rejected")
        end

        def credential_name_for(profile_role, provider)
          ref = profile_credential_reference(profile_role, provider)
          return credential_env_key(provider) unless ref

          ref.fetch("name")
        end

        def profile_credential_reference(profile_role, provider)
          return unless profile_role

          ref = profile_role.credential_ref
          return if ref.nil?
          unless ref.is_a?(Hash) && ref["kind"] == "env" &&
                 ref["name"].is_a?(String) && ref["name"].match?(/\A[A-Z][A-Z0-9_]*\z/)
            raise ProfileRoleUnavailableError, "model_role/credential_reference_invalid"
          end
          if ref.fetch("name") == api_base_name(provider)
            raise ProfileRoleUnavailableError, "model_role/credential_reference_invalid"
          end
          ref
        end

        def credential_env_key(provider)
          Providers::ENV_KEYS.fetch(provider.to_sym)
        end

        def api_base_name(provider)
          "#{provider.upcase}_API_BASE"
        end

        def profile_endpoint(profile_role)
          settings = profile_role&.normalized_settings || {}
          settings["base_url"] || settings["api_base"]
        end

        def ensure_credential!(value, provider, profile_role:, credential_name:)
          return if !value.to_s.empty? || provider == "ollama"

          raise_credential_unavailable(profile_role, credential_name)
        end

        # The refusal names the role and the reference (DR-5 D1): the operator
        # pinned a specific credential, so the generic provider key is noise.
        def raise_credential_unavailable(profile_role, name)
          if profile_role
            raise ProfileRoleUnavailableError,
                  "model_role/credential_unavailable: #{profile_role.name} (#{name})"
          end

          raise ModelCallError.new(code: "credential_unavailable")
        end

        def ensure_endpoint!(endpoint, provider)
          return if endpoint.is_a?(String) && !endpoint.empty?

          raise ModelCallError.new(code: "endpoint_unavailable")
        end

        def normalize_safety(safety)
          value = safety.to_sym if safety.respond_to?(:to_sym)
          return value if %i[unsafe idempotent].include?(value)

          raise ModelCallError.new(code: "safety_invalid")
        end

        def environment_value(environment, name)
          return environment[name] if environment.respond_to?(:[])

          environment.to_h.fetch(name, nil)
        end

        def configuration_document(provider, model, endpoint, descriptor, role, safety)
          {
            "provider" => provider,
            "model" => model,
            "endpoint" => endpoint,
            "protocol" => descriptor.fetch(:protocol),
            "settings" => EpisodeModelTransport::SETTINGS,
            "profile_role" => role_document(role),
            "profile_digest" => role&.profile_digest,
            "safety" => safety.to_s
          }
        end

        def role_document(role)
          return nil unless role

          {
            "name" => role.name,
            "provider" => role.provider,
            "model" => role.model,
            "revision" => role.revision,
            "normalized_settings" => role.normalized_settings,
            "credential_ref" => role.credential_ref&.slice("kind", "name"),
            "profile_digest" => role.profile_digest
          }
        end
      end
    end
  end
end
