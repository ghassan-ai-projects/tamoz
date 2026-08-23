# frozen_string_literal: true

require_relative "test_helper"

class AgentRubyLLMModelTest < Minitest::Test
  Config = Struct.new(:openai_api_key, :openai_api_base, :openrouter_api_key, :openrouter_api_base)

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

  def test_binds_deepseek_to_openrouter_without_using_the_direct_deepseek_provider
    config = Config.new
    context = FakeContext.new
    context_factory = lambda do |&block|
      block.call(config)
      context
    end

    model = Tamoz::Agent::RubyLLMModel.new(
      model: "deepseek/deepseek-chat",
      provider: :openrouter,
      api_key: "openrouter-test-key",
      context_factory:
    )
    model.generate(stage: :plan, system: "system", prompt: "prompt")

    assert_equal "openrouter-test-key", config.openrouter_api_key
    assert_nil config.openrouter_api_base
    assert_equal(
      {model: "deepseek/deepseek-chat", provider: :openrouter, assume_model_exists: false},
      context.arguments
    )
  end

  def test_ruby_llm_model_registry_loads_under_a_c_locale
    script = <<~RUBY
      require "tamoz/agent"
      model = Tamoz::Agent::RubyLLMModel.new(
        model: "deepseek-chat",
        provider: :deepseek,
        api_key: "test-key"
      )
      model.instance_variable_get(:@context).chat(
        model: "deepseek-chat", provider: :deepseek, assume_model_exists: false
      )
      puts Encoding.default_external.name
    RUBY
    load_paths = %w[
      tamoz-core tamoz-graph tamoz-scheduler tamoz-stream tamoz-approval tamoz-sqlite
      tamoz-tools tamoz-observability tamoz-comms
      tamoz-agent-kernel tamoz-agent-memory tamoz-agent-healing tamoz-agent-profile tamoz-agent-improvement
      tamoz-agent-kernel tamoz-agent-memory tamoz-agent-healing tamoz-agent-profile tamoz-agent-improvement
      tamoz-agent
    ].map do |name|
      "-I#{GEM_ROOTS.fetch(name).join('lib')}"
    end
    stdout, stderr, status = Open3.capture3(
      {"LC_ALL" => "C", "LANG" => "C"},
      RbConfig.ruby,
      *load_paths,
      "-e",
      script
    )

    assert_predicate status, :success?, "#{stdout}\n#{stderr}"
    assert_equal "UTF-8\n", stdout
  end
end
