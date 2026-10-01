# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require_relative 'support/research_spec'

# `tamoz deep-research` end to end over the real websearch adapter process serving the fixture web: the plan is asked
# on the terminal, answered, and the cited report lands in the workspace's research/. Scripted models: plumbing only.
# rubocop:disable Minitest/MultipleAssertions -- one run read from several sides.
class AgentCliResearchTest < Minitest::Test
  include AutonomyCase
  include ResearchSpec

  ADAPTER = ROOT.join('script', 'websearch_adapter').to_s
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB TAMOZ_WEBSEARCH_GRANT
                     TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER].freeze
  EXCERPT = 'Oslo had 717,710 residents on 1 January 2025, up 1.2 percent from a year earlier.'

  def test_deep_research_asks_the_plan_on_the_terminal_and_saves_the_report_in_the_workspace
    with_fixture_web do
      with_runtime do |runtime|
        configure_websearch(runtime)
        status = out = err = nil
        writes = atomic_writes { status, out, err = run_cli(runtime, input: "go\n") }

        assert_equal 0, status, err
        assert_includes err, 'Here is my research plan.'
        report = Dir[File.join(runtime.workspace, 'research', '*', 'report.md')].first

        refute_nil report, out
        assert_replaced writes, report, 0o644
        assert_includes File.read(report), "[1] Population of Oslo - Statistics Norway. #{SSB}."
        assert_includes out, 'The full report is saved at'
        refute_includes out, 'probe'
      end
    end
  end

  def test_a_research_thread_paused_at_its_plan_resumes_with_an_answer
    with_fixture_web do
      with_runtime do |runtime|
        configure_websearch(runtime)
        model = research_team
        paused, = run_cli(runtime, input: '', model:, args: ['--session', 'oslo', 'deep-research', QUESTION])

        refute_equal 0, paused
        status, out, err = run_cli(runtime, input: '', model:, args: ['resume', 'oslo', '--answer', 'go'])

        assert_equal 0, status, err
        assert_includes out, 'The full report is saved at'
        refute_empty Dir[File.join(runtime.workspace, 'research', '*', 'report.md')]
      end
    end
  end

  def test_deep_research_refuses_to_change_files
    with_runtime do |runtime|
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(['--root', runtime.workspace, '--allow-changes', 'deep-research', 'x'],
                                     out: StringIO.new, err:, input: StringIO.new, env: {})

      refute_equal 0, status
      assert_match(/read-only/, err.string)
    end
  end

  def test_research_budgets_narrow_the_run_and_stay_with_the_thread
    with_fixture_web do
      with_runtime do |runtime|
        configure_websearch(runtime)
        budgets = File.join(runtime.dir, 'budgets.json')
        File.write(budgets, JSON.generate('depths' => { 'quick' => { 'minutes' => 1 } }))
        err = nil
        writes = atomic_writes do
          _status, _out, err = run_cli(runtime, input: '', args: ['--session', 'oslo', '--research-budgets', budgets,
                                                                  'deep-research', QUESTION])
        end
        pin_path = File.join(runtime.dir, 'sessions', 'oslo.harness.json')
        pin = JSON.parse(File.read(pin_path))

        assert_includes writes, [:replace, pin_path, 0o600]
        assert_equal({ 'depths' => { 'quick' => { 'minutes' => 1 } } }, pin.fetch('research_budgets'))
        assert_includes err, 'about 1 minutes'
      end
    end
  end

  def test_research_budgets_that_raise_a_number_are_refused
    with_runtime do |runtime|
      budgets = File.join(runtime.dir, 'budgets.json')
      File.write(budgets, JSON.generate('depths' => { 'quick' => { 'searches' => 999 } }))
      status, _out, err = run_cli(runtime, input: '', args: ['--research-budgets', budgets, 'deep-research', QUESTION])

      refute_equal 0, status
      assert_includes err, 'may only lower'
    end
  end

  private

  def assert_replaced(writes, path, mode)
    published = writes.map { |operation, written, written_mode| [operation, File.realpath(written), written_mode] }

    assert_includes published, [:replace, File.realpath(path), mode]
  end

  def research_team
    SubagentFixtures::ScriptedTeam.new(
      parent: [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
               { calls: [report_call('Oslo had 717,710 residents at the start of 2025 [C1].')] }],
      child: reading_child('Q1', 'Oslo population statistics', EXCERPT), reviews: [{ 'unsupported' => [] }]
    )
  end

  def run_cli(runtime, input:, model: research_team, args: ['deep-research', QUESTION])
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(
      ['--runtime-dir', runtime.dir, '--session-dir', File.join(runtime.dir, 'sessions'), '--root', runtime.workspace,
       *args],
      out:, err:, input: StringIO.new(input), env: {}, model_factory: ->(_options) { model }
    )
    [status, out.string, err.string]
  end

  def configure_websearch(runtime)
    path = File.join(runtime.dir, 'config.yaml')
    document = Psych.safe_load_file(path)
    document['sources'] = { 'websearch' => { 'enabled' => true, 'command' => RbConfig.ruby, 'arguments' => [ADAPTER],
                                             'env_allowlist' => ENV_ALLOWLIST,
                                             'read_only_tools' => %w[search read_page] } }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end
end
# rubocop:enable Minitest/MultipleAssertions
