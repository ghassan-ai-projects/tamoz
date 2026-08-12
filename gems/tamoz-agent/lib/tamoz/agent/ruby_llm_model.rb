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

      def generate(stage:, system:, prompt:, emitter: nil)
        chat = @context.chat(
          model:,
          provider:,
          assume_model_exists: @assume_model_exists
        )
        ordinal = 0
        emit_model_event(emitter, :model_started, {
          ordinal:, provider:, model_id: @model, stage:
        }) if emitter
        response = chat.with_instructions(system).ask(prompt)
        emit_model_event(emitter, :model_delta, {
          ordinal:, content: response.content
        }) if emitter
        emit_model_event(emitter, :model_completed, {
          ordinal:, usage: usage_of(response)
        }) if emitter
        response.content
      rescue StandardError => error
        if defined?(RubyLLM::Error) && error.is_a?(RubyLLM::Error)
          raise ProtocolError, "#{stage} model call failed: #{error.class}: #{error.message}"
        end

        raise
      end

      private

      def emit_model_event(emitter, type, data)
        emitter.emit(type, data, run_id: nil, task_id: nil)
      end

      # Raw usage extraction: the episode stream adapter maps this hash to the
      # wire Usage message (the model client cannot reference the stream
      # proto). Nil-safe — providers report different usage shapes.
      def usage_of(response)
        usage = response.respond_to?(:usage) ? response.usage : nil
        return {input_tokens: 0, output_tokens: 0} unless usage

        {
          input_tokens: integer_usage(usage, :input_tokens),
          output_tokens: integer_usage(usage, :output_tokens),
          cached_input_tokens: integer_usage(usage, :cached_input_tokens),
          reasoning_tokens: integer_usage(usage, :reasoning_tokens),
          cost_microunits: cost_microunits_of(usage)
        }
      end

      def integer_usage(usage, field)
        value = usage.respond_to?(field) ? usage.public_send(field) : nil
        value.is_a?(Numeric) ? value.to_i : 0
      end

      def cost_microunits_of(usage)
        cost = usage.respond_to?(:cost) ? usage.cost : nil
        cost.is_a?(Numeric) ? (cost * 1_000_000).round : 0
      end

      def assign(config, writer, value)
        unless config.respond_to?(writer)
          raise ArgumentError, "RubyLLM does not support #{provider} configuration"
        end

        config.public_send(writer, value)
      end
    end
  end
end
