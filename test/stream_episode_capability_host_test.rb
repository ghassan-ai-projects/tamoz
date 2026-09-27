# frozen_string_literal: true

require_relative "test_helper"

# T4.1 (THREAT_MODEL §4) — the stream-episode capability host. The episode
# tool surface is the fixed allowlist from §4.1; the host holds no reference
# to any effectful machinery; the injection corpus proves a denied tool cannot
# be named, discovered, or bound; and the call path scrubs the context so an
# effect journal or store is not reachable from inside the boundary.
class StreamEpisodeCapabilityHostTest < Minitest::Test
  Host = Tamoz::Stream::EpisodeCapabilityHost

  PERMITTED = Host::PERMITTED

  # The THREAT_MODEL §4.2 denied surface plus the real toolbox tool names an
  # injected instruction would actually try, plus arbitrary strings — the
  # mechanism is deny-by-default, so any name outside PERMITTED must refuse.
  DENIED_NAMES = %w[
    write_file edit_file bash read_file list_dir grep delegate interrupt
    websearch mcp_call check_runner admit_episode apply_patch delete_file
    create_file rename_file run_check search_text list_directory load_skill
    read_skill_resource effect_intent effect_receipt write save patch run
    exec curl fetch create delete approve zzz_arbitrary_injected_name
  ].freeze

  # The denied machinery and primitives a dependency-direction scan must not
  # find in the episode path.
  DENIED_TOKENS = %w[
    Toolbox EffectJournal Mcp CheckRunner Websearch WriteFile EditFile
    BashOperation StagingReaper PatchOperations CreationOperations
    Open3 IO.popen Process.spawn File.write File.delete FileUtils
  ].freeze

  def implementations
    PERMITTED.to_h { |id| [id, ->(_arguments, _context) { {id => "ok"} }] }
  end

  def test_the_surface_is_exactly_the_permitted_allowlist
    host = Host.new(implementations)

    assert_equal PERMITTED, host.names
    assert_equal PERMITTED, host.descriptors.map { |entry| entry.fetch("name") }
    host.descriptors.each do |descriptor|
      assert descriptor.fetch("read_only")
      assert descriptor.fetch("bounded_rows")
      assert descriptor.fetch("bounded_bytes")
    end
    PERMITTED.each { |id| assert host.permitted?(id) }
  end

  def test_every_denied_tool_is_unknown
    host = Host.new(implementations)

    DENIED_NAMES.each do |name|
      assert_raises(Tamoz::Core::ToolError, "#{name} must not resolve") do
        host.assert_permitted!(name)
      end
      assert_raises(Tamoz::Core::ToolError, "#{name} must not execute") do
        host.execute(name, {})
      end
    end
  end

  def test_an_injected_instruction_cannot_bind_a_denied_capability
    # A compromised composition trying to slip an effector into the host is
    # refused at construction: unknown keys never enter the surface.
    assert_raises(Tamoz::ConfigurationError) do
      Host.new(implementations.merge("bash" => ->(_args, _ctx) { "pwned" }))
    end
    assert_raises(Tamoz::ConfigurationError) do
      Host.new(implementations.merge("write_file" => ->(_args, _ctx) { "pwned" }))
    end
    # Missing implementations are refused too — the surface cannot be silently
    # shrunk to hide a tool the worker depends on.
    assert_raises(Tamoz::ConfigurationError) do
      Host.new(implementations.except(PERMITTED.first))
    end
  end

  def test_permitted_tools_execute_through_the_bound_implementations
    host = Host.new(implementations)
    result = host.execute("knowledge.search", {"query" => "x"})
    assert_equal({"knowledge.search" => "ok"}, result)
  end

  # THREAT_MODEL §4.3: the call path must not expose the effect journal or the
  # store. A tool implementation receives only the allowlisted context
  # attributes — a full Tamoz::Context (with effects/store) is scrubbed.
  def test_the_context_passed_to_a_tool_never_carries_effects_or_store
    seen = nil
    host = Host.new(
      implementations.merge(
        "features.query" => ->(_args, context) { seen = context }
      )
    )
    full_context = Tamoz::Context.new(
      run_id: "run.1",
      execution_id: "execution.1",
      request_id: "request.1",
      effects: Object.new,
      store: Object.new
    )
    host.execute("features.query", {}, context: full_context)

    refute_nil seen
    refute_includes seen.keys, :store
    refute_includes seen.keys, :effects
    assert_equal "run.1", seen[:run_id]
    assert seen.frozen?
  end

  def test_result_bounds_are_enforced_not_declared
    host = Host.new(
      implementations.merge(
        "forecast.run" => ->(_args, _ctx) { "x" * (Host::MAX_RESULT_BYTES + 1) }
      )
    )
    error = assert_raises(Tamoz::Core::ToolError) do
      host.execute("forecast.run", {})
    end
    assert_includes error.message, "limit"
  end

  def test_the_host_wraps_only_non_tamoz_errors_and_discloses_no_message
    host = Host.new(
      implementations.merge(
        "forecast.run" => ->(_args, _ctx) { raise "boom with secret token abc123" }
      )
    )
    error = assert_raises(Tamoz::Core::ToolError) do
      host.execute("forecast.run", {})
    end
    assert_includes error.message, "RuntimeError"
    refute_includes error.message, "secret token"
  end

  # THREAT_MODEL §4.3.2: the dependency-direction test. The episode path must
  # not reference the effectful modules — proven by source scan AND by an
  # env-scrubbed clean-subprocess load that pulls in none of the effectful gems.
  def test_dependency_direction_episode_path_has_no_effectful_reference
    # The containment set: the episode host now, plus the worker files the
    # later phases add. A new episode-path file must be added here OR the
    # directory assertion below fails.
    episode_files = ROOT.glob(
      "gems/tamoz-stream/lib/tamoz/stream/{capability_host,episode_*,evidence_*,decision_*,situation_*}*.rb"
    )
    refute_empty episode_files, "no episode-path files scanned"
    episode_files.each do |path|
      content = File.read(path)
      DENIED_TOKENS.each do |token|
        refute_includes content, token,
                        "#{path} must not reference #{token}"
      end
      refute_includes content, "require_relative",
                      "#{path} must not require sibling modules"
    end
  end

  def test_the_host_loads_without_the_effectful_gems
    script = <<~RUBY
      require "tamoz/core"
      require "tamoz/stream/capability_host"
      # The host must not have pulled any effectful tamoz gem into the
      # process. $LOADED_FEATURES is the ground truth: a transitive require
      # of tamoz-tools/agent/mcp/sqlite would appear here (the gems are
      # installed, so a require would succeed — which is exactly why the
      # absence of the reference must be proven by what was loaded, not by a
      # failed require).
      effectful = $LOADED_FEATURES.grep(%r{
        tamoz/(tools|agent|sqlite|mcp|comms|scheduler|telegram|observability|otel|evals)
      }x)
      abort "effectful gem loaded: \#{effectful.join(", ")}" unless effectful.empty?
      host = Tamoz::Stream::EpisodeCapabilityHost.new({
        #{PERMITTED.map { |id| "\"#{id}\" => ->(_a, _c) { 1 }" }.join(", ")}
      })
      puts host.names.join(",")
    RUBY
    env = ENV.each_key.grep(/\A(?:BUNDLE|BUNDLER)/).to_h { |key| [key, nil] }
    env.merge!("RUBYLIB" => nil, "RUBYOPT" => nil)
    output, error, status = Open3.capture3(
      env, RbConfig.ruby, *SUBPROCESS_LIB_ARGS, "-e", script
    )
    assert status.success?, "isolated episode host load failed: #{error}"
    assert_equal PERMITTED.join(","), output.strip
  end

  def test_go_spelled_stream_names_reach_the_dotted_implementation
    host = Host.new(implementations)

    assert_equal({"evidence.get" => "ok"}, host.execute("evidence_get", {}))
    assert_equal({"history.prior_incidents" => "ok"}, host.execute("history_prior_incidents", {}))
    assert Host.stream_tool?("evidence_get")
    refute Host.stream_tool?("probe_pond_log")
  end

  def test_probes_bind_only_under_probe_names_and_nothing_ungranted_executes
    probe = ->(_arguments, _context) { {"json" => "log"} }
    host = Host.new(implementations, probes: {"probe_pond_log" => probe}, granted: %w[probe_pond_log evidence_get])

    assert_equal({"json" => "log"}, host.execute("probe_pond_log", {}))
    assert_equal({"evidence.get" => "ok"}, host.execute("evidence_get", {}))
    error = assert_raises(Tamoz::Core::ToolError) { host.execute("knowledge.search", {}) }
    assert_match(/not granted/, error.message)
    assert_raises(Tamoz::ConfigurationError) { Host.new(implementations, probes: {"read_file" => probe}) }
    ungranted = Host.new(implementations, probes: {"probe_pond_log" => probe}, granted: %w[evidence_get])
    assert_raises(Tamoz::Core::ToolError) { ungranted.execute("probe_pond_log", {}) }
  end
end
