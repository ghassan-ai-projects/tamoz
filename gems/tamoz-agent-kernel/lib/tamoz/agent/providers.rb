# frozen_string_literal: true

module Tamoz
  module Agent
    # The provider catalog: every supported model provider and the credential
    # environment variable that carries its key. Lives in the kernel because
    # both the model adapter (runtime) and trusted-profile validation
    # (tamoz-agent-profile) consume it — below each of them.
    module Providers
      ENV_KEYS = {
        anthropic: "ANTHROPIC_API_KEY",
        deepseek: "DEEPSEEK_API_KEY",
        gemini: "GEMINI_API_KEY",
        mistral: "MISTRAL_API_KEY",
        ollama: "OLLAMA_API_KEY",
        openai: "OPENAI_API_KEY",
        openrouter: "OPENROUTER_API_KEY",
        perplexity: "PERPLEXITY_API_KEY",
        xai: "XAI_API_KEY"
      }.freeze
    end
  end
end
