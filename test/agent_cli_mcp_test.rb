# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class AgentCliMcpTest < Minitest::Test
  include AutonomyCase

  SERVER_SCRIPT = ROOT.join('script', 'mcp_test_server').to_s
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Minitest/MultipleAssertions
  def test_cli_ask_builds_and_executes_the_configured_mcp_source
    with_runtime do |rt|
      configure_mcp(rt)
      session_dir = File.join(rt.dir, 'sessions')
      model = nil
      factory = lambda do |_options|
        model = ScriptedModel.new(
          plan: [mcp_plan],
          review: [accepted_review],
          verify: [{ 'answer' => 'live-evidence', 'satisfied' => true,
                     'evidence' => ['mcp:probe/echo_constant'] }]
        )
      end

      out = StringIO.new
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', rt.dir, '--session-dir', session_dir, '--root', rt.workspace,
         '--session', 'cli-mcp', '--json', 'ask', 'query the MCP server'],
        out:, err:, input: StringIO.new, env: {}, model_factory: factory
      )

      assert_equal 0, status, err.string
      assert_includes model.calls.find { |call| call[:stage] == :plan }.fetch(:prompt),
                      'mcp:probe/echo_constant'
      refute_includes model.calls.find { |call| call[:stage] == :plan }.fetch(:prompt),
                      '"tool": "echo_constant"'
      receipt = mcp_receipt(rt, session_dir)

      assert_equal 'tool.mcp:probe/echo_constant', receipt.fetch('operation')
      assert_equal 'succeeded', receipt.fetch('status')
      assert_includes out.string, '"status":"completed"'
    end
  end

  def test_invalid_mcp_arguments_are_repaired_before_execution
    with_runtime do |rt|
      configure_mcp(rt)
      model = ScriptedModel.new(
        plan: [invalid_mcp_plan, mcp_plan],
        review: [accepted_review],
        verify: [{ 'answer' => 'live-evidence', 'satisfied' => true, 'evidence' => [] }]
      )

      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', rt.dir, '--session-dir', File.join(rt.dir, 'sessions'),
         '--root', rt.workspace, '--session', 'invalid-mcp', 'ask', 'query'],
        out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {},
        model_factory: ->(_options) { model }
      )

      assert_equal 0, status
      plan_calls = model.calls.count { |call| call[:stage] == :plan }

      assert_equal 2, plan_calls
      assert_includes model.calls[1].fetch(:prompt), 'disallowed additional property'
    end
  end

  def test_mcp_errors_are_adapted_to_the_agent_tool_taxonomy
    with_runtime do |rt|
      configure_mcp(rt)
      source = Tamoz::Agent::McpSourceBuilder.new(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      ).build

      error = assert_raises(Tamoz::Agent::ToolArgumentError) do
        source.validate('mcp:probe/echo_constant', { 'value' => 'ok', 'sort' => 'bad' })
      end
      assert_predicate error, :repairable?

      original_call = Tamoz::Mcp::Invocation.method(:call)
      Tamoz::Mcp::Invocation.define_singleton_method(:call) do |*_args, **_kwargs|
        raise Tamoz::Mcp::ToolArgumentError, 'invalid MCP arguments'
      end
      begin
        error = assert_raises(Tamoz::Agent::ToolArgumentError) do
          source.execute({}, 'mcp:probe/echo_constant', { 'value' => 'ok' })
        end
        assert_predicate error, :repairable?
      ensure
        Tamoz::Mcp::Invocation.define_singleton_method(:call, original_call)
      end
    ensure
      source&.close
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Minitest/MultipleAssertions

  # rubocop:disable Metrics/AbcSize
  def test_cli_runtime_flag_takes_precedence_over_runtime_environment
    with_runtime do |rt|
      configure_mcp(rt)
      session_dir = File.join(rt.dir, 'sessions')
      model = nil
      factory = lambda do |_options|
        model = ScriptedModel.new(
          plan: [mcp_plan], review: [accepted_review],
          verify: [{ 'answer' => 'live-evidence', 'satisfied' => true, 'evidence' => [] }]
        )
      end

      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', rt.dir, '--session-dir', session_dir, '--root', rt.workspace,
         '--session', 'flag-wins', 'ask', 'query the MCP server'],
        out: StringIO.new, err: StringIO.new, input: StringIO.new,
        env: { 'TAMOZ_RUNTIME_DIR' => File.join(rt.dir, 'missing') }, model_factory: factory
      )

      assert_equal 0, status
      assert_includes model.calls.map { |call| call[:stage] }, :plan
    end
  end
  # rubocop:enable Metrics/AbcSize

  def test_cli_without_runtime_configuration_keeps_mcp_disabled
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new,
                                input: StringIO.new, env: {})

    assert_nil cli.send(:build_mcp_source, { root: Dir.pwd })
  end

  def test_cli_rejects_a_runtime_workspace_that_differs_from_the_cli_workspace
    with_runtime do |rt|
      configure_mcp(rt)
      other_workspace = File.join(rt.dir, 'other-workspace')
      FileUtils.mkdir_p(other_workspace)
      model = ScriptedModel.new(plan: [mcp_plan], review: [accepted_review], verify: [])
      factory = ->(_options) { model }
      err = StringIO.new

      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', rt.dir, '--session-dir', File.join(rt.dir, 'sessions'),
         '--root', other_workspace, '--session', 'wrong-root', 'ask', 'query'],
        out: StringIO.new, err:, input: StringIO.new, env: {}, model_factory: factory
      )

      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(/does not match/, err.string)
    end
  end

  private

  def configure_mcp(runtime)
    path = File.join(runtime.dir, 'config.yaml')
    document = Psych.safe_load_file(path)
    document['sources'] = {
      'mcp' => {
        'enabled' => true,
        'servers' => [{
          'id' => 'probe',
          'command' => RbConfig.ruby,
          'arguments' => [SERVER_SCRIPT],
          'env_allowlist' => ENV_ALLOWLIST,
          'read_only_tools' => ['echo_constant']
        }]
      }
    }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end

  def mcp_plan
    {
      'goal' => 'query the MCP server',
      'done_when' => ['the server evidence is present'],
      'steps' => [{
        'id' => 'mcp-query',
        'purpose' => 'query the governed MCP server',
        'tool' => 'mcp:probe/echo_constant',
        'arguments' => { 'value' => 'live-evidence' },
        'verification' => 'the server returned live-evidence'
      }]
    }
  end

  def invalid_mcp_plan
    mcp_plan.merge(
      'steps' => [mcp_plan.fetch('steps').first.merge('arguments' => {
        'value' => 'live-evidence', 'sort' => 'timestamp:desc'
      })]
    )
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def mcp_receipt(runtime, session_dir)
    source = Tamoz::Agent::McpSourceBuilder.new(
      Tamoz::Agent::RuntimeDirectory.resolve(path: runtime.dir, env: {})
    ).build
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(session_dir, 'cli-mcp.sqlite3'),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
    )
    dummy_model = Object.new
    dummy_model.define_singleton_method(:generate) { |**| '{}' }
    session = Tamoz::Agent::Session.new(
      model: dummy_model,
      toolbox: Tamoz::Agent::Toolbox.new(root: runtime.workspace),
      checkpointer: adapter,
      mcp: source
    )
    session.view(thread: 'cli-mcp').effect_receipts.find do |entry|
      entry.fetch('operation') == 'tool.mcp:probe/echo_constant'
    end
  ensure
    source&.close
    adapter&.close unless adapter&.closed?
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def accepted_review = { 'decision' => 'accept', 'issues' => [], 'rationale' => 'sound' }
end
