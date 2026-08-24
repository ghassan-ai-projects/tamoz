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

  # P16: the tools gem must load core only — zero graph/sqlite/agent/evals/
  # ruby_llm features, exactly the boundary the packaged install test also proves.
  def test_tools_loads_core_only_and_no_agent_graph_or_sqlite
    features = loaded_features_after("tamoz/tools")

    assert_includes features, "tamoz/core.rb"
    assert_includes features, "tamoz/tools.rb"
    assert_includes features, "tamoz/tools/toolbox.rb"
    assert_includes features, "tamoz/tools/skills.rb"
    refute(
      features.any? { |path| path.match?(%r{tamoz/(?:graph|sqlite|agent|evals)|ruby_llm}) },
      features.inspect
    )
  end

  # P1: the kernel gem loads core + tools and nothing else. Kernel files
  # install under lib/tamoz/agent/ just like the runtime gem's, so a bare
  # "tamoz/agent" refute cannot work — allowlist exactly the union of the
  # three gems' own trees (derived from their roots); any loaded feature
  # outside the union is an upward or sideways edge.
  def test_kernel_loads_core_and_tools_only
    allowed = %w[tamoz-core tamoz-tools tamoz-agent-kernel].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/agent_kernel")

    assert_includes features, "tamoz/core.rb"
    assert_includes features, "tamoz/tools.rb"
    assert_includes features, "tamoz/agent_kernel.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
  end

  # PA: the capabilities gem loads core + tools + kernel only, and keeps the
  # MCP surface lazy — requiring the umbrella must not pull tamoz/mcp.
  def test_capabilities_loads_core_tools_kernel_only_and_keeps_mcp_lazy
    allowed = %w[tamoz-core tamoz-tools tamoz-agent-kernel tamoz-agent-capabilities].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/agent_capabilities")

    assert_includes features, "tamoz/agent_capabilities.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
    refute_includes features, "tamoz/mcp.rb"
  end

  def test_agent_defers_provider_loading_and_does_not_load_evals_or_sqlite
    features = loaded_features_after("tamoz/agent")

    assert_includes features, "tamoz/agent.rb"
    refute(
      features.any? do |path|
        path.match?(%r{\Aruby/gems/.+ruby_llm|tamoz/evals|tamoz/sqlite})
      end,
      features.inspect
    )
    # The agent must not depend upward on tamoz-stream. The shared situation
    # recall contract lives in tamoz-core, not tamoz-stream (audit P-02).
    # (tamoz/stream_part and tamoz/stream_sink are tamoz-core files, not the
    # stream gem, so match only the stream gem's require path.)
    refute(
      features.any? { |path| path.match?(%r{/tamoz/stream[./]}) },
      "require \"tamoz/agent\" must not load tamoz/stream: #{features.grep(%r{/tamoz/stream[./]}).inspect}"
    )
  end

  # GB-02/EU-004: tamoz-evals is a development/release harness whose verifier and
  # scorecard subtree reference Tamoz::Agent/SQLite/Mcp/Graph/Scheduler directly.
  # It is deliberately runtime-coupled — NOT stdlib-only. The architectural rule
  # is the INVERSE edge: no production gem depends on evals
  # (test_no_production_gemspec_depends_on_evals). Here we pin that the coupling
  # is real and declared, so an accidental future decoupling is visible.
  def test_evals_is_a_runtime_coupled_release_harness
    features = loaded_features_after("tamoz/evals")

    assert_includes features, "tamoz/evals.rb"
    %w[tamoz/core.rb tamoz/agent.rb tamoz/sqlite.rb tamoz/mcp.rb].each do |declared|
      assert_includes features, declared,
                      "tamoz/evals must load its declared runtime harness dependency #{declared}"
    end
  end

  def test_mcp_loads_only_core_and_the_official_sdk
    features = loaded_features_after("tamoz/mcp")

    assert_includes features, "tamoz/core.rb"
    assert_includes features, "tamoz/mcp.rb"
    refute(
      features.any? { |path| path.match?(%r{ruby_llm|tamoz/(?:graph|sqlite|agent|evals)}) },
      features.inspect
    )
  end

  # Audit F2: the decision builder is the tamoz-stream injected-port boundary —
  # it must load without tamoz-agent (the P4 edge, reintroduced by 747d350 and
  # now homed in tamoz-core). This pins the no-edge property at the source
  # level.
  def test_decision_builder_loads_core_only_and_no_agent_edge
    features = loaded_features_after("tamoz/stream/decision_builder")

    assert_includes features, "tamoz/core.rb"
    assert_includes features, "tamoz/stream/decision_builder.rb"
    refute(
      features.any? { |path| path.match?(%r{tamoz/agent}) },
      features.inspect
    )
  end

  # ADR-041: tamoz-comms is a VALUES and CONTRACT gem — core only. It must not
  # pull the durable store, the agent, or any model client, and it must not
  # open a socket at load time. This is what keeps the channel vocabulary out
  # of the HTTP-carrying transport and the credential-carrying worker.
  # The subprocess proof loads tamoz/comms and asserts every forbidden feature
  # is absent from one load graph.
  def test_comms_loads_core_only_and_no_http_or_agent
    script = <<~RUBY
      require "json"
      require "socket"
      require "tamoz/comms"
      puts JSON.generate(
        "comms" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/comms") },
        "net_http" => $LOADED_FEATURES.any? { |path| path.include?("net/http") },
        "openssl" => $LOADED_FEATURES.any? { |path| path.include?("openssl") },
        "graph" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/graph") },
        "sqlite" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/sqlite") },
        "agent" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/agent") },
        "evals" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/evals") },
        "ruby_llm" => $LOADED_FEATURES.any? { |path| path.include?("ruby_llm") }
      )
    RUBY
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *LOAD_PATH_ARGUMENTS,
      "-e",
      script
    )
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("comms")
    %w[net_http openssl graph sqlite agent evals ruby_llm].each do |feature|
      refute result.fetch(feature), "#{feature} must not be in the load graph"
    end
  end

  # tamoz-observability is the signal-plane contract gem: core only, no HTTP
  # client and no exporter in a minimal boot (dependency rule 5).
  def test_observability_loads_core_only_and_no_http_or_agent
    script = <<~RUBY
      require "json"
      require "tamoz/observability"
      puts JSON.generate(
        "observability" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/observability") },
        "core" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/core") },
        "net_http" => $LOADED_FEATURES.any? { |path| path.include?("net/http") },
        "openssl" => $LOADED_FEATURES.any? { |path| path.include?("openssl") },
        "graph" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/graph") },
        "sqlite" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/sqlite") },
        "agent" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/agent") },
        "evals" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/evals") },
        "ruby_llm" => $LOADED_FEATURES.any? { |path| path.include?("ruby_llm") }
      )
    RUBY
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *LOAD_PATH_ARGUMENTS,
      "-e",
      script
    )
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("observability")
    assert result.fetch("core")
    %w[net_http openssl graph sqlite agent evals ruby_llm].each do |feature|
      refute result.fetch(feature), "#{feature} must not be in the load graph"
    end
  end

  def test_no_production_gemspec_depends_on_evals
    production = GEM_ROOTS.except("tamoz-evals")

    production.each do |name, root|
      spec = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
      refute_includes spec.runtime_dependencies.map(&:name), "tamoz-evals", name
    end
  end

  # Audit F2: the injected-port boundary at the PACKAGE level too — no
  # production gemspec may depend on tamoz-agent except tamoz-agent's own
  # dependents (agent, tools). The tamoz-stream gemspec must stay
  # core/grpc/protobuf only. tamoz-evals is excluded because it is a
  # development/release harness, not a production gem (GB-02) — it exercises
  # every public boundary, including agent, and nothing depends on it in turn.
  def test_no_production_gemspec_depends_on_agent_except_agents_own_dependents
    allowed = %w[tamoz-agent tamoz-tools tamoz-agent-cli]

    GEM_ROOTS.except("tamoz-evals").each do |name, root|
      next if allowed.include?(name)

      spec = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
      refute_includes spec.runtime_dependencies.map(&:name), "tamoz-agent", name
    end
  end

  # ADR-041: tamoz-telegram is the HTTP-carrying transport — it depends only
  # on tamoz-comms (values/contracts) and the stdlib; it must not pull the
  # agent, the durable store, or any model client into a gateway process.
  def test_telegram_loads_comms_and_stdlib_but_no_agent_or_store
    script = <<~RUBY
      require "json"
      require "tamoz/telegram"
      puts JSON.generate(
        "comms" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/comms") },
        "net_http" => $LOADED_FEATURES.any? { |path| path.include?("net/http") },
        "graph" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/graph") },
        "sqlite" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/sqlite") },
        "agent" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/agent") },
        "ruby_llm" => $LOADED_FEATURES.any? { |path| path.include?("ruby_llm") }
      )
    RUBY
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *LOAD_PATH_ARGUMENTS,
      "-e",
      script
    )
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("comms")
    assert result.fetch("net_http")
    %w[graph sqlite agent ruby_llm].each do |feature|
      refute result.fetch(feature), "#{feature} must not be in the gateway load graph"
    end
  end

  private

  def clean_environment
    ENV.each_key
       .grep(/\A(?:BUNDLE|BUNDLER)/)
       .to_h { |key| [key, nil] }
       .merge("RUBYLIB" => nil, "RUBYOPT" => nil)
  end

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
