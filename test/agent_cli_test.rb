# frozen_string_literal: true

require_relative "test_helper"

class AgentCLITest < Minitest::Test
  def test_version_needs_no_provider_configuration
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["--version"], out:, err:, env: {})

    assert_equal 0, status
    assert_equal "#{Tamoz::Agent::VERSION}\n", out.string
    assert_empty err.string
  end

  def test_missing_task_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run([], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/TASK/, err.string)
  end

  def test_missing_model_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["inspect this"], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/TAMOZ_MODEL/, err.string)
  end

  def test_check_configuration_requires_explicit_change_mode
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["--check", "test=ruby -c example.rb", "inspect"],
      out:,
      err:,
      env: {"TAMOZ_MODEL" => "model", "OPENAI_API_KEY" => "key"}
    )

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/requires --allow-changes/, err.string)
  end
end
