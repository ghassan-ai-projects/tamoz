# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class AgentProbeIntegrationTest < Minitest::Test
  include AutonomyCase

  SERVER_SCRIPT = ROOT.join('script', 'mcp_test_server').to_s
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze

  def test_a_configured_probe_runs_over_real_mcp_and_hides_its_backing_server
    with_runtime do |runtime|
      configure(runtime)
      source = Tamoz::Agent::McpSourceBuilder.new(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime.dir,
                                                                                         env: {})).build
      begin
        assert_equal ['probe_echo_status'], source.names
        outcome = source.execute(nil, 'probe_echo_status', { 'target' => 'motor-1' })

        assert_equal 'status of motor-controller', outcome.observation.text

        binding = Tamoz::Agent::CapabilityBinding.build(toolbox: Tamoz::Agent::Toolbox.new(root: runtime.workspace),
                                                        mcp: source)

        assert_includes binding.names(:discovery), 'probe_echo_status'
        refute(binding.names(:action).any? { |name| name.start_with?('mcp:probe/') })
        assert_equal :read_only, binding.effect_class('probe_echo_status')
        assert_equal({ 'probe_echo_status' => 'Echo the unit status.' },
                     binding.remote_planning_surface(['probe_echo_status']))
      ensure
        source.close
      end
    end
  end

  def test_a_probe_over_a_tool_not_declared_read_only_stops_the_build
    with_runtime do |runtime|
      configure(runtime, read_only_tools: [])
      builder = Tamoz::Agent::McpSourceBuilder.new(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime.dir, env: {}))
      error = assert_raises(Tamoz::Agent::McpSourceBuilder::Error) { builder.build }

      assert_match(/not declared read-only/, error.message)
    end
  end

  def test_probes_without_any_mcp_server_stop_the_build
    with_runtime do |runtime|
      configure(runtime)
      path = File.join(runtime.dir, 'config.yaml')
      document = Psych.safe_load_file(path)
      document['sources'].delete('mcp')
      File.write(path, Psych.dump(document))
      builder = Tamoz::Agent::McpSourceBuilder.new(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime.dir, env: {}))

      assert_raises(Tamoz::Agent::McpSourceBuilder::Error) { builder.build }
    end
  end

  private

  def configure(runtime, read_only_tools: ['echo_constant'])
    path = File.join(runtime.dir, 'config.yaml')
    document = Psych.safe_load_file(path)
    document['sources'] = {
      'mcp' => { 'enabled' => true, 'servers' => [{
        'id' => 'probe', 'command' => RbConfig.ruby, 'arguments' => [SERVER_SCRIPT],
        'env_allowlist' => ENV_ALLOWLIST, 'read_only_tools' => read_only_tools
      }] },
      'probes' => { 'enabled' => true,
                    'targets' => { 'motor-1' => { 'unit' => 'motor-controller' } },
                    'probes' => [{ 'name' => 'probe_echo_status', 'description' => 'Echo the unit status.',
                                   'backing' => { 'server' => 'probe', 'tool' => 'echo_constant' },
                                   'arguments' => { 'value' => 'status of {target.unit}' } }] }
    }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
