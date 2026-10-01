# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'

# The creator end to end with scripted models: a verified thread becomes a staged candidate in a private drafting
# workspace. Plumbing only: no model is called.
class CliSkillsCreateTest < Minitest::Test
  include WorkLoopFixtures

  SKILL = <<~MARKDOWN
    ---
    name: set-constant
    description: Change one constant safely and prove it with the project's check. Use when a constant holds the wrong value.
    metadata:
      tamoz.risk: guarded
    ---

    1. Read the file that defines the constant.
    2. Patch only that constant.
    3. Run the configured check before finishing.
  MARKDOWN

  def tamoz(argv, turns, input: "y\n" * 20)
    model = ScriptedConversationModel.new(turns:)
    err = StringIO.new
    out = StringIO.new
    status = Tamoz::Agent::CLI.run(argv, out:, err:, input: StringIO.new(input),
                                         env: { 'TAMOZ_CONTEXT_WINDOW' => '20000' }, model_factory: ->(_) { model })
    [status, err.string]
  end

  def test_a_verified_thread_becomes_a_staged_candidate
    Dir.mktmpdir('tamoz-create') do |dir|
      workspace = File.join(dir, 'ws')
      sessions = File.join(dir, 'sessions')
      FileUtils.mkdir_p(File.join(workspace, 'lib'))
      FileUtils.mkdir_p(sessions, mode: 0o700)
      File.write(File.join(workspace, 'lib', 'value.rb'), "VALUE = 1\n")
      source = [{ calls: [plan_call] }, { calls: [read_call('lib/value.rb')] },
                ->(_) { { calls: [patch_call(workspace, 'lib/value.rb', 'VALUE = 1', 'VALUE = 2')] } },
                { calls: [['run_check', { 'name' => 'test' }]] }, { content: 'Set VALUE to 2; the test check passed.' }]
      status, err = tamoz(['--root', workspace, '--session-dir', sessions, '--session', 'fix-value', '--allow-changes',
                           '--check', 'test=true', 'code', 'Set VALUE to 2'], source)

      assert_equal 0, status, err
      draft = [{ calls: [plan_call(paths: %w[set-constant], checks: [])] },
               { calls: [['create_file', { 'path' => 'set-constant/SKILL.md', 'content' => SKILL }]] },
               { content: 'Drafted set-constant.' }]
      status, err = tamoz(['--session-dir', sessions, 'skills', 'create', 'set-constant', '--from-session', 'fix-value'],
                          draft)

      assert_equal 0, status, err
      manifest = Dir[File.join(sessions, 'skill-drafts', '*', 'set-constant.candidate.json')].first

      refute_nil manifest
      assert_equal %w[tamoz.skill-creator session:fix-value], JSON.parse(File.read(manifest)).values_at('created_by', 'source')
      assert_includes File.read(File.join(File.dirname(manifest), 'trajectory.md')), 'Set VALUE to 2'
    end
  end
end
