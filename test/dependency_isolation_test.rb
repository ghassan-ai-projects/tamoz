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
    allowed = %w[tamoz-core tamoz-cancellation tamoz-tools tamoz-agent-kernel].flat_map { |name|
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
    allowed = %w[tamoz-core tamoz-cancellation tamoz-tools tamoz-agent-kernel tamoz-agent-capabilities].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/agent_capabilities")

    assert_includes features, "tamoz/agent_capabilities.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
    refute_includes features, "tamoz/mcp.rb"
  end

  # C1: tamoz-cancellation is the lowest substrate above core. It loads core
  # and nothing else — and never tamoz/concurrency, whose one-way edge points
  # DOWN into this gem.
  def test_cancellation_loads_core_only_and_keeps_concurrency_above_it
    allowed = %w[tamoz-core tamoz-cancellation].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/cancellation")

    assert_includes features, "tamoz/cancellation.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
    refute_includes features, "tamoz/concurrency.rb"
  end

  # C2: concurrency consumes cancellation + core (Clock, errors, token); no
  # upward or sideways edge may ride along with the umbrella require.
  def test_concurrency_loads_core_and_cancellation_only
    allowed = %w[tamoz-core tamoz-cancellation tamoz-concurrency].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/concurrency")

    assert_includes features, "tamoz/concurrency.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
    refute_includes features, "tamoz/graph.rb"
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

  # GB-02/EU-004: tamoz-evals is the verifier and artifact package. The
  # scorecard subtree now lives in tamoz-evals-runner.
  # The architectural rule remains one-way: production gems do not depend on
  # either evaluation package.
  def test_evals_loads_the_verifier_boundary_only
    features = loaded_features_after("tamoz/evals")

    assert_includes features, "tamoz/evals.rb"
    assert_includes features, "tamoz/core.rb"
    refute features.any? { |path| path.match?(%r{tamoz/(?:agent|sqlite|mcp|graph|scheduler|comms|evals/runner)}) },
           features.inspect
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

  def test_mcp_loads_without_websearch_http_or_resolv
    state = loaded_state_after("tamoz/mcp")
    features = state.fetch("features")

    refute features.any? { |path| path.end_with?("/tamoz/mcp/websearch.rb") }, features.inspect
    refute features.any? { |path| path.match?(%r{(?:net/http|resolv)}) }, features.inspect
    assert_nil state.fetch("websearch_defined")
  end

  def test_websearch_loads_only_its_declared_tamoz_closure
    allowed = %w[tamoz-cancellation tamoz-core tamoz-mcp tamoz-mcp-websearch].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/mcp/websearch")

    assert_includes features, "tamoz/mcp/websearch.rb"
    assert_includes features, "tamoz/mcp/websearch/version.rb"
    unexpected = features.reject { |path| allowed.include?(path) || path.match?(%r{\A(?:mcp|net/http|resolv|uri|ipaddr)}) }
    assert_empty unexpected, unexpected.inspect
  end

  def test_websearch_gemspec_declares_exactly_mcp_and_core
    spec = Gem::Specification.load(GEM_ROOTS.fetch("tamoz-mcp-websearch").join("tamoz-mcp-websearch.gemspec").to_s)

    assert_equal(
      {
        "tamoz-core" => "= 0.1.0.alpha.1",
        "tamoz-mcp" => "= 0.1.0.alpha.1"
      },
      spec.runtime_dependencies.to_h { |dependency| [dependency.name, dependency.requirement.to_s] }
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
        "ruby_llm" => $LOADED_FEATURES.any? { |path| path.include?("ruby_llm") },
        "gateway_defined" => defined?(Tamoz::Comms::Gateway),
        "drainer_defined" => defined?(Tamoz::Comms::DeliveryDrainer)
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
    assert_nil result.fetch("gateway_defined")
    assert_nil result.fetch("drainer_defined")
  end

  def test_comms_gateway_loads_only_comms_core_and_gateway
    allowed = %w[tamoz-core tamoz-comms tamoz-comms-gateway].flat_map { |name|
      library = GEM_ROOTS.fetch(name).join("lib")
      Dir.glob(library.join("tamoz/**/*.rb")).map { |path| path.delete_prefix("#{library}/") }
    }.uniq.sort
    features = loaded_features_after("tamoz/comms/gateway")

    assert_includes features, "tamoz/comms/gateway.rb"
    assert_includes features, "tamoz/comms/delivery_drainer.rb"
    unexpected = features.reject { |path| allowed.include?(path) }
    assert_empty unexpected, unexpected.inspect
  end

  def test_comms_gateway_gemspec_declares_only_its_contract_dependencies
    spec = Gem::Specification.load(
      GEM_ROOTS.fetch("tamoz-comms-gateway").join("tamoz-comms-gateway.gemspec").to_s
    )

    assert_equal(
      {
        "tamoz-comms" => "= 0.1.0.alpha.1",
        "tamoz-core" => "= 0.1.0.alpha.1"
      },
      spec.runtime_dependencies.to_h { |dependency| [dependency.name, dependency.requirement.to_s] }
    )
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
    production = GEM_ROOTS.except("tamoz-evals", "tamoz-evals-runner")

    production.each do |name, root|
      spec = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
      refute_includes spec.runtime_dependencies.map(&:name), "tamoz-evals", name
    end
  end

  # Audit F2: the injected-port boundary at the PACKAGE level too — no
  # production gemspec may depend on tamoz-agent except tamoz-agent's own
  # dependents (agent, tools). The tamoz-stream gemspec must stay
  # core/grpc/protobuf only. Evaluation packages are excluded because they are
  # development/release companions, not production gems.
  def test_no_production_gemspec_depends_on_agent_except_agents_own_dependents
    allowed = %w[tamoz-agent tamoz-tools tamoz-agent-cli]

    GEM_ROOTS.except("tamoz-evals", "tamoz-evals-runner").each do |name, root|
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

  def loaded_state_after(require_path)
    script = <<~RUBY
      require "json"
      require #{require_path.inspect}
      puts JSON.generate(
        "features" => $LOADED_FEATURES,
        "websearch_defined" => defined?(Tamoz::Mcp::Websearch)
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
