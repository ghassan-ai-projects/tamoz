# frozen_string_literal: true

require_relative "test_helper"

class AgentRubyLLMModelTest < Minitest::Test
  Config = Struct.new(:openai_api_key, :openai_api_base)

  class FakeChat
    attr_reader :instructions, :prompt

    def with_instructions(value)
      @instructions = value
      self
    end

    def ask(value)
      @prompt = value
      Struct.new(:content).new("{\"ok\":true}")
    end
  end

  class FakeContext
    attr_reader :arguments, :chat_instance

    def initialize
      @chat_instance = FakeChat.new
    end

    def chat(**arguments)
      @arguments = arguments
      @chat_instance
    end
  end

  def test_uses_an_isolated_ruby_llm_context_for_one_generation
    config = Config.new
    context = FakeContext.new
    context_factory = lambda do |&block|
      block.call(config)
      context
    end

    model = Tamoz::Agent::RubyLLMModel.new(
      model: "local-model",
      provider: :openai,
      api_key: "test-key",
      api_base: "http://127.0.0.1:1234/v1",
      assume_model_exists: true,
      context_factory:
    )
    result = model.generate(stage: :plan, system: "system", prompt: "prompt")

    assert_equal "{\"ok\":true}", result
    assert_equal "test-key", config.openai_api_key
    assert_equal "http://127.0.0.1:1234/v1", config.openai_api_base
    assert_equal "system", context.chat_instance.instructions
    assert_equal "prompt", context.chat_instance.prompt
    assert_equal(
      {model: "local-model", provider: :openai, assume_model_exists: true},
      context.arguments
    )
  end

  def test_requires_credentials_for_remote_providers
    error = assert_raises(ArgumentError) do
      Tamoz::Agent::RubyLLMModel.new(model: "model", provider: :openai, api_key: "")
    end

    assert_match(/OPENAI_API_KEY/, error.message)
  end
end
