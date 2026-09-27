# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require_relative 'support/work_loop_fixtures'

# `tamoz investigate` and `tamoz probes` over the real MCP test server, with a scripted model: plumbing only.
class AgentCliInvestigateTest < Minitest::Test
  include AutonomyCase
  include WorkLoopFixtures

  SERVER_SCRIPT = ROOT.join('script', 'mcp_test_server').to_s
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze

  def report_call
    ['report_findings', {
      'summary' => 'The unit reports its status.', 'hypothesis' => 'The motor controller is up.',
      'confidence' => 'low',
      'findings' => [{ 'statement' => 'The probe answered with the unit status.', 'evidence' => ['call_1_0'] }],
      'gaps' => [], 'proposals' => []
    }]
  end

  def test_investigate_json_prints_a_grounded_report_and_exits_zero
    with_runtime do |runtime|
      configure(runtime)
      model = ScriptedConversationModel.new(turns: [{ calls: [['probe_unit_status', { 'target' => 'motor-1' }]] },
                                                    { calls: [report_call] }])
      out = StringIO.new
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', runtime.dir, '--session-dir', File.join(runtime.dir, 'sessions'), '--root', runtime.workspace,
         '--json', 'investigate', 'Is the motor controller up?'],
        out:, err:, input: StringIO.new, env: {}, model_factory: ->(_options) { model }
      )
      document = JSON.parse(out.string.lines.last).fetch('data')

      assert_equal 0, status, err.string
      assert_equal 'low', document.fetch('report').fetch('confidence')
      assert_equal ['call_1_0'], document.fetch('report').fetch('findings').first.fetch('evidence')
      tool_result = JSON.parse(model.requests.last).fetch('messages').find { |message| message['role'] == 'tool' }

      assert_equal 'status of motor-controller', tool_result.fetch('content')
    end
  end

  def test_investigate_refuses_anything_but_a_read_only_turn
    with_runtime do |runtime|
      [%w[--allow-changes], %w[--approval-profile auto], %w[--profile any]].each do |flags|
        err = StringIO.new
        status = Tamoz::Agent::CLI.run(['--root', runtime.workspace, *flags, 'investigate', 'x'],
                                       out: StringIO.new, err:, input: StringIO.new, env: {})

        refute_equal 0, status, flags.join(' ')
        assert_match(/read-only|not supported|invalid option/, err.string)
      end
    end
  end

  def test_probes_lists_and_validates_the_catalog_without_starting_a_server
    with_runtime do |runtime|
      configure(runtime, command: '/nonexistent/mcp-server')
      out = StringIO.new
      status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime.dir, 'probes'],
                                     out:, err: StringIO.new, input: StringIO.new, env: {})

      assert_equal 0, status
      assert_includes out.string, 'probe_unit_status  reads mcp:unit/echo_constant  pinned: value  free: -'
      json = StringIO.new
      Tamoz::Agent::CLI.run(['--runtime-dir', runtime.dir, '--json', 'probes'],
                            out: json, err: StringIO.new, input: StringIO.new, env: {})

      assert_equal ['motor-1'], JSON.parse(json.string).fetch('targets')
      configure(runtime, read_only_tools: [])
      err = StringIO.new
      refused = Tamoz::Agent::CLI.run(['--runtime-dir', runtime.dir, 'probes'],
                                      out: StringIO.new, err:, input: StringIO.new, env: {})

      refute_equal 0, refused
      assert_includes err.string, 'not declared read-only'
    end
  end

  private

  def configure(runtime, command: RbConfig.ruby, read_only_tools: ['echo_constant'])
    path = File.join(runtime.dir, 'config.yaml')
    document = Psych.safe_load_file(path)
    document['sources'] = {
      'mcp' => { 'enabled' => true, 'servers' => [{
        'id' => 'unit', 'command' => command, 'arguments' => [SERVER_SCRIPT],
        'env_allowlist' => ENV_ALLOWLIST, 'read_only_tools' => read_only_tools
      }] },
      'probes' => { 'enabled' => true, 'targets' => { 'motor-1' => { 'unit' => 'motor-controller' } },
                    'probes' => [{ 'name' => 'probe_unit_status', 'description' => 'Status of the unit.',
                                   'backing' => { 'server' => 'unit', 'tool' => 'echo_constant' },
                                   'arguments' => { 'value' => 'status of {target.unit}' } }] }
    }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
