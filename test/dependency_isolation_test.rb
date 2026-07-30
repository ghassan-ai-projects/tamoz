# frozen_string_literal: true

require_relative "test_helper"

class DependencyIsolationTest < Minitest::Test
  LOAD_PATH_ARGUMENTS = GEM_ROOTS.values.flat_map { |root| ["-I", root.join("lib").to_s] }.freeze

  def test_graph_loads_no_model_eval_or_adapter_package
    features = loaded_features_after("tamoz/graph")

    assert_includes features, "tamoz/core.rb"
    assert_includes features, "tamoz/graph.rb"
    refute(
      features.any? { |path| path.match?(%r{ruby_llm|tamoz/evals|tamoz/sqlite|tamoz/agent}) },
      features.inspect
    )
  end

  def test_core_loads_only_its_declared_runtime_boundary
    features = loaded_features_after("tamoz/core")

    assert_includes features, "tamoz/core.rb"
    refute(
      features.any? { |path| path.match?(%r{tamoz/(?:graph|sqlite|agent|evals)|ruby_llm}) },
      features.inspect
    )
  end

  def test_agent_does_not_load_evals_sqlite_or_rubyllm_in_m0
    features = loaded_features_after("tamoz/agent")

    assert_includes features, "tamoz/agent.rb"
    refute(
      features.any? { |path| path.match?(%r{ruby_llm|tamoz/evals|tamoz/sqlite}) },
      features.inspect
    )
  end

  def test_evals_is_stdlib_only_and_loads_no_runtime_package
    features = loaded_features_after("tamoz/evals")

    assert_includes features, "tamoz/evals.rb"
    refute(
      features.any? { |path| path.match?(%r{tamoz/(?:core|graph|sqlite|agent)}) },
      features.inspect
    )
  end

  def test_no_production_gemspec_depends_on_evals
    production = GEM_ROOTS.except("tamoz-evals")

    production.each do |name, root|
      spec = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
      refute_includes spec.runtime_dependencies.map(&:name), "tamoz-evals", name
    end
  end

  private

  def loaded_features_after(require_path)
    script = <<~RUBY
      require "json"
      require #{require_path.inspect}
      puts JSON.generate(
        $LOADED_FEATURES
          .select { |path| path.include?("/tamoz/") || path.include?("ruby_llm") }
          .map { |path| path.sub(%r{.*?/lib/}, "") }
          .sort
      )
    RUBY
    clean_environment = ENV.each_key
                           .grep(/\A(?:BUNDLE|BUNDLER)/)
                           .to_h { |key| [key, nil] }
                           .merge("RUBYLIB" => nil, "RUBYOPT" => nil)
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *LOAD_PATH_ARGUMENTS,
      "-e",
      script
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end
end
