# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions
class OpenclawBenchmarkEnvironmentLoaderTest < Minitest::Test
  def test_loads_only_the_selected_provider_entries_from_dotenv
    Dir.mktmpdir('openclaw-env') do |directory|
      path = File.join(directory, '.env')
      File.write(path, <<~ENV)
        OPENROUTER_API_KEY="router-key"
        OPENROUTER_API_BASE=https://openrouter.example/v1
        DEEPSEEK_API_KEY=direct-key
        TELEGRAM_BOT_TOKEN=should-not-load
      ENV

      environment = Tamoz::Evals::Benchmark::EnvironmentLoader.for(
        provider: 'openrouter', env_file: path, environment: { 'PATH' => '/bin' }
      )

      assert_equal 'router-key', environment.fetch('OPENROUTER_API_KEY')
      assert_equal 'https://openrouter.example/v1', environment.fetch('OPENROUTER_API_BASE')
      refute environment.key?('DEEPSEEK_API_KEY')
      refute environment.key?('TELEGRAM_BOT_TOKEN')
    end
  end

  def test_shell_environment_takes_precedence_over_dotenv
    Dir.mktmpdir('openclaw-env') do |directory|
      path = File.join(directory, '.env')
      File.write(path, "OPENROUTER_API_KEY=file-key\n")

      environment = Tamoz::Evals::Benchmark::EnvironmentLoader.for(
        provider: 'openrouter', env_file: path,
        environment: { 'OPENROUTER_API_KEY' => 'shell-key' }
      )

      assert_equal 'shell-key', environment.fetch('OPENROUTER_API_KEY')
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
