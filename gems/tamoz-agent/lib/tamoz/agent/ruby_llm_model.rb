# frozen_string_literal: true

module Tamoz
  module Agent
    class RubyLLMModel
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

      attr_reader :model, :provider

      def initialize(
        model:,
        provider:,
        api_key: nil,
        api_base: nil,
        assume_model_exists: false,
        context_factory: nil
      )
        @model = String(model).dup.freeze
        @provider = String(provider).downcase.to_sym
        key = api_key || ENV[ENV_KEYS.fetch(@provider) do
          raise ArgumentError, "unsupported CLI provider #{@provider.inspect}"
        end]
        if key.to_s.empty? && @provider != :ollama
          raise ArgumentError, "#{ENV_KEYS.fetch(@provider)} is required"
        end

        unless context_factory
          # RubyLLM reads its bundled model registry with File.read. A C locale
          # tags that UTF-8 JSON as US-ASCII, so JSON.parse fails before the first
          # provider request. Tamoz's model and prompt contracts are UTF-8.
          Encoding.default_external = Encoding::UTF_8 unless
            Encoding.default_external == Encoding::UTF_8
          require "ruby_llm"
          context_factory = RubyLLM.method(:context)
        end

        @context = context_factory.call do |config|
          assign(config, "#{@provider}_api_key=", key) unless key.to_s.empty?
          assign(config, "#{@provider}_api_base=", api_base) unless api_base.to_s.empty?
        end
        @assume_model_exists = assume_model_exists
      end

      def generate(stage:, system:, prompt:)
        chat = @context.chat(
          model:,
          provider:,
          assume_model_exists: @assume_model_exists
        )
        chat.with_instructions(system).ask(prompt).content
      rescue StandardError => error
        if defined?(RubyLLM::Error) && error.is_a?(RubyLLM::Error)
          raise ProtocolError, "#{stage} model call failed: #{error.class}: #{error.message}"
        end

        raise
      end

      private

      def assign(config, writer, value)
        unless config.respond_to?(writer)
          raise ArgumentError, "RubyLLM does not support #{provider} configuration"
        end

        config.public_send(writer, value)
      end
    end
  end
end
